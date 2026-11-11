#include "BoardNativeTracker.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <vector>

namespace {
constexpr int maximumEdge = 960;
constexpr int minimumInliers = 16;
using Clock = std::chrono::steady_clock;
using Quad = std::array<cv::Point2d, 4>;

double cross(const cv::Point2d &a, const cv::Point2d &b, const cv::Point2d &c) {
    return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x);
}
double area(const Quad &q) {
    double value = 0;
    for (int i=0; i<4; ++i) value += q[i].x*q[(i+1)%4].y-q[(i+1)%4].x*q[i].y;
    return value * 0.5;
}
bool validQuad(const Quad &q, double width, double height, bool seed) {
    const double lower = seed ? 0 : -0.5, upper = seed ? 1 : 1.5;
    for (int i=0; i<4; ++i) {
        const auto &p=q[i];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x/width<lower || p.x/width>upper ||
            p.y/height<lower || p.y/height>upper || cross(p,q[(i+1)%4],q[(i+2)%4])<=1e-4 ||
            cv::norm(p-q[(i+1)%4])<std::min(width,height)*0.015) return false;
    }
    return area(q)>width*height*0.0025;
}
bool validImage(const uint8_t *data, int width, int height, size_t stride) {
    return data && width>=32 && height>=32 && width<=16384 && height<=16384 && stride>=size_t(width)*4;
}
cv::Mat reducedGray(const uint8_t *data, int width, int height, size_t stride) {
    cv::Mat bgra(height,width,CV_8UC4,const_cast<uint8_t *>(data),stride), reduced, gray;
    const double scale=std::min(1.0,double(maximumEdge)/std::max(width,height));
    if (scale<1) cv::resize(bgra,reduced,cv::Size(int(std::lround(width*scale)),int(std::lround(height*scale))),0,0,cv::INTER_AREA);
    else reduced=bgra;
    cv::cvtColor(reduced,gray,cv::COLOR_BGRA2GRAY);
    return gray;
}
cv::Rect2d bounds(const Quad &q) {
    double x0=q[0].x,x1=x0,y0=q[0].y,y1=y0;
    for (const auto &p:q) { x0=std::min(x0,p.x); x1=std::max(x1,p.x); y0=std::min(y0,p.y); y1=std::max(y1,p.y); }
    return {x0,y0,x1-x0,y1-y0};
}
double hullCoverage(const std::vector<cv::Point2f> &points, const Quad &q) {
    if (points.size()<3) return 0;
    std::vector<cv::Point2f> hull; cv::convexHull(points,hull);
    return cv::contourArea(hull)/area(q);
}
bool spatialSupport(const std::vector<cv::Point2f> &points, const Quad &q) {
    if (points.empty()) return false;
    const auto box=bounds(q);
    float x0=points[0].x,x1=x0,y0=points[0].y,y1=y0;
    unsigned cells=0;
    for (const auto &p:points) {
        x0=std::min(x0,p.x); x1=std::max(x1,p.x); y0=std::min(y0,p.y); y1=std::max(y1,p.y);
        const int x=std::clamp(int((p.x-box.x)/box.width*3),0,2), y=std::clamp(int((p.y-box.y)/box.height*3),0,2);
        cells |= 1u << (y*3+x);
    }
    int occupied=0; for (;cells;cells>>=1) occupied+=cells&1u;
    return x1-x0>=box.width*0.45 && y1-y0>=box.height*0.25 && occupied>=4;
}
bool project(const cv::Mat &H, const cv::Point2d &p, cv::Point2d &out, double *denominator=nullptr) {
    const double z=H.at<double>(2,0)*p.x+H.at<double>(2,1)*p.y+H.at<double>(2,2);
    if (!std::isfinite(z) || std::abs(z)<1e-8) return false;
    out={(H.at<double>(0,0)*p.x+H.at<double>(0,1)*p.y+H.at<double>(0,2))/z,
         (H.at<double>(1,0)*p.x+H.at<double>(1,1)*p.y+H.at<double>(1,2))/z};
    if (denominator) *denominator=z;
    return std::isfinite(out.x)&&std::isfinite(out.y);
}
bool projectedQuad(const cv::Mat &H, const Quad &reference, cv::Size refSize, cv::Size size, Quad &q) {
    double sign=0,minimumDenominator=std::numeric_limits<double>::infinity(),maximumDenominator=0;
    for (int i=0;i<4;++i) {
        double z;
        if (!project(H,reference[i],q[i],&z) || (i && z*sign<=0)) return false;
        sign=z; minimumDenominator=std::min(minimumDenominator,std::abs(z)); maximumDenominator=std::max(maximumDenominator,std::abs(z));
    }
    if (minimumDenominator/maximumDenominator<0.2 || !validQuad(q,size.width,size.height,false)) return false;
    const double scale=double(size.area())/refSize.area(), ratio=area(q)/(area(reference)*scale);
    if (ratio<0.2 || ratio>4) return false;
    double minimumEdgeScale=std::numeric_limits<double>::infinity(),maximumEdgeScale=0;
    for (int i=0;i<4;++i) {
        const double edgeScale=cv::norm(q[i]-q[(i+1)%4])/cv::norm(reference[i]-reference[(i+1)%4])/std::sqrt(scale);
        minimumEdgeScale=std::min(minimumEdgeScale,edgeScale); maximumEdgeScale=std::max(maximumEdgeScale,edgeScale);
    }
    return minimumEdgeScale>=0.25 && maximumEdgeScale<=3 && maximumEdgeScale/minimumEdgeScale<=3;
}
void outputCorners(BNTResult &result, const Quad &quad, cv::Size size) {
    for (int i=0;i<4;++i) { result.corners[i*2]=quad[i].x/size.width; result.corners[i*2+1]=quad[i].y/size.height; }
}
struct Timer {
    Clock::time_point start=Clock::now();
    double milliseconds() const { return std::chrono::duration<double,std::milli>(Clock::now()-start).count(); }
};
}

struct BNTTracker {
    cv::Ptr<cv::SIFT> sift=cv::SIFT::create(1600,3,0.008,12);
    std::vector<cv::KeyPoint> referenceFeatures;
    cv::Mat referenceDescriptors;
    Quad referenceQuad{};
    cv::Size referenceSize;
    bool seeded=false;
    void reset() { referenceFeatures.clear(); referenceDescriptors.release(); referenceSize={}; referenceQuad={}; seeded=false; }
};

extern "C" BNTTracker *BNTCreate(void) {
    try {
        static std::once_flag setup;
        std::call_once(setup,[]{ cv::setNumThreads(2); });
        return new BNTTracker;
    } catch (...) { return nullptr; }
}
extern "C" void BNTDestroy(BNTTracker *tracker) { delete tracker; }
extern "C" void BNTReset(BNTTracker *tracker) { if (tracker) tracker->reset(); }

extern "C" BNTResult BNTSeed(BNTTracker *tracker,const uint8_t *bgra,int32_t width,int32_t height,
                             size_t stride,const double *corners8,const uint8_t *excludeMask,size_t maskStride) {
    Timer timer; BNTResult result{};
    auto finish=[&](int rejection) { result.rejectionCode=rejection; result.analysisMilliseconds=timer.milliseconds(); return result; };
    if (!tracker) return finish(BNT_REJECTION_ARGUMENT);
    tracker->reset();
    if (!validImage(bgra,width,height,stride)||!corners8||(excludeMask&&maskStride<size_t(width))) return finish(BNT_REJECTION_ARGUMENT);
    try {
        const cv::Mat gray=reducedGray(bgra,width,height,stride);
        Quad quad; for (int i=0;i<4;++i) quad[i]={corners8[i*2]*gray.cols,corners8[i*2+1]*gray.rows};
        if (!validQuad(quad,gray.cols,gray.rows,true)) return finish(BNT_REJECTION_GEOMETRY);
        cv::Mat mask=cv::Mat::zeros(gray.size(),CV_8UC1);
        std::vector<cv::Point> polygon; for (auto p:quad) polygon.emplace_back(cvRound(p.x),cvRound(p.y));
        cv::fillConvexPoly(mask,polygon,cv::Scalar(255));
        if (excludeMask) {
            cv::Mat exclusion(height,width,CV_8UC1,const_cast<uint8_t *>(excludeMask),maskStride), reduced;
            cv::resize(exclusion,reduced,gray.size(),0,0,cv::INTER_NEAREST);
            cv::dilate(reduced,reduced,cv::getStructuringElement(cv::MORPH_ELLIPSE,{5,5}));
            mask.setTo(0,reduced);
        }
        std::vector<cv::KeyPoint> features; cv::Mat descriptors;
        tracker->sift->detectAndCompute(gray,mask,features,descriptors);
        result.featureCount=result.referenceFeatureCount=int(features.size());
        if (features.size()<minimumInliers || descriptors.empty()) return finish(BNT_REJECTION_FEATURES);
        std::vector<cv::Point2f> points; for (const auto &k:features) points.push_back(k.pt);
        result.coverage=hullCoverage(points,quad);
        if (result.coverage<0.15 || !spatialSupport(points,quad)) return finish(BNT_REJECTION_COVERAGE);
        tracker->referenceFeatures=std::move(features); tracker->referenceDescriptors=std::move(descriptors);
        tracker->referenceQuad=quad; tracker->referenceSize=gray.size(); tracker->seeded=true;
        result.status=1; result.confidence=1; outputCorners(result,quad,gray.size());
        return finish(BNT_REJECTION_NONE);
    } catch (...) { tracker->reset(); return finish(BNT_REJECTION_EXCEPTION); }
}

extern "C" BNTResult BNTProcess(BNTTracker *tracker,const uint8_t *bgra,int32_t width,int32_t height,size_t stride) {
    Timer timer; BNTResult result{};
    auto finish=[&](int rejection) { result.rejectionCode=rejection; result.analysisMilliseconds=timer.milliseconds(); return result; };
    if (!tracker||!validImage(bgra,width,height,stride)) return finish(BNT_REJECTION_ARGUMENT);
    if (!tracker->seeded) return finish(BNT_REJECTION_UNSEEDED);
    result.referenceFeatureCount=int(tracker->referenceFeatures.size());
    try {
        const cv::Mat gray=reducedGray(bgra,width,height,stride);
        std::vector<cv::KeyPoint> features; cv::Mat descriptors;
        tracker->sift->detectAndCompute(gray,cv::noArray(),features,descriptors);
        result.featureCount=int(features.size());
        if (features.size()<minimumInliers||descriptors.empty()) return finish(BNT_REJECTION_FEATURES);
        cv::BFMatcher matcher(cv::NORM_L2);
        std::vector<std::vector<cv::DMatch>> forward,reverse;
        matcher.knnMatch(tracker->referenceDescriptors,descriptors,forward,2);
        matcher.knnMatch(descriptors,tracker->referenceDescriptors,reverse,2);
        std::vector<int> reverseIndex(features.size(),-1);
        for (const auto &pair:reverse) if (pair.size()==2&&pair[0].distance<0.75f*pair[1].distance) reverseIndex[pair[0].queryIdx]=pair[0].trainIdx;
        std::vector<cv::DMatch> candidates;
        for (const auto &pair:forward) if (pair.size()==2&&pair[0].distance<0.75f*pair[1].distance&&
            reverseIndex[pair[0].trainIdx]==pair[0].queryIdx) candidates.push_back(pair[0]);
        std::sort(candidates.begin(),candidates.end(),[](const auto &a,const auto &b){ return a.distance<b.distance; });
        std::vector<cv::Point2f> source,destination;
        // SIFT may produce multiple orientations at one location: these are one
        // geometric observation, not independent RANSAC support.
        for (const auto &m:candidates) {
            auto a=tracker->referenceFeatures[m.queryIdx].pt,b=features[m.trainIdx].pt;
            bool duplicate=false;
            for (size_t i=0;i<source.size();++i) if (cv::norm(a-source[i])<1.25||cv::norm(b-destination[i])<1.25) { duplicate=true; break; }
            if (!duplicate) { source.push_back(a); destination.push_back(b); }
        }
        result.matches=int(source.size());
        if (source.size()<minimumInliers) return finish(BNT_REJECTION_MATCHES);
        cv::Mat inlierMask;
        const cv::Mat H=cv::findHomography(source,destination,cv::USAC_MAGSAC,2.5,inlierMask,5000,0.999);
        if (H.empty()||!cv::checkRange(H)) return finish(BNT_REJECTION_HOMOGRAPHY);
        cv::Mat inverse;
        if (!cv::invert(H,inverse,cv::DECOMP_LU)||!cv::checkRange(inverse)) return finish(BNT_REJECTION_HOMOGRAPHY);
        Quad quad;
        if (!projectedQuad(H,tracker->referenceQuad,tracker->referenceSize,gray.size(),quad)) return finish(BNT_REJECTION_GEOMETRY);
        std::vector<cv::Point2f> inlierSource,inlierDestination;
        std::vector<double> errors;
        for (size_t i=0;i<source.size();++i) if (inlierMask.at<uint8_t>(int(i))) {
            cv::Point2d a,b;
            if (!project(H,source[i],a)||!project(inverse,destination[i],b)) return finish(BNT_REJECTION_HOMOGRAPHY);
            errors.push_back(std::max(cv::norm(a-cv::Point2d(destination[i])),cv::norm(b-cv::Point2d(source[i]))));
            inlierSource.push_back(source[i]); inlierDestination.push_back(destination[i]);
        }
        result.inliers=int(errors.size());
        if (errors.size()<minimumInliers||double(errors.size())/source.size()<0.5) return finish(BNT_REJECTION_INLIERS);
        std::sort(errors.begin(),errors.end());
        result.medianError=errors[errors.size()/2]; result.p95Error=errors[size_t(std::ceil(errors.size()*0.95))-1];
        if (result.medianError>1.5||result.p95Error>3) return finish(BNT_REJECTION_ERROR);
        result.coverage=hullCoverage(inlierSource,tracker->referenceQuad);
        if (result.coverage<0.15||hullCoverage(inlierDestination,quad)<0.15||
            !spatialSupport(inlierSource,tracker->referenceQuad)||!spatialSupport(inlierDestination,quad)) return finish(BNT_REJECTION_COVERAGE);
        result.status=1;
        result.confidence=std::clamp(double(result.inliers)/result.matches*(1-result.medianError/6),0.0,1.0);
        outputCorners(result,quad,gray.size());
        return finish(BNT_REJECTION_NONE);
    } catch (...) { return finish(BNT_REJECTION_EXCEPTION); }
}
