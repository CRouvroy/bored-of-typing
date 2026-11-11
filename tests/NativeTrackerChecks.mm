#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "BoardNativeTracker.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

struct Image {
    int width,height;
    std::vector<uint8_t> pixels;
    size_t stride() const { return size_t(width)*4; }
};
static Image load(const char *path) {
    NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
    if (!source) { std::fprintf(stderr,"Cannot load %s\n",path); std::exit(1); }
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,nullptr);
    CFRelease(source);
    Image result{int(CGImageGetWidth(image)),int(CGImageGetHeight(image)),{}};
    result.pixels.resize(result.stride()*result.height);
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(result.pixels.data(),result.width,result.height,8,result.stride(),color,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    CGContextDrawImage(context,CGRectMake(0,0,result.width,result.height),image);
    CGContextRelease(context); CGColorSpaceRelease(color); CGImageRelease(image);
    return result;
}
static int checks=0;
static void expect(bool value,const char *message) {
    if (!value) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); } ++checks;
}
static void report(const char *label,const BNTResult &r) {
    std::printf("%s status=%d rejection=%d features=%d/%d matches=%d inliers=%d coverage=%.3f symmetric median/p95=%.3f/%.3f ms=%.1f quad=",label,r.status,r.rejectionCode,r.featureCount,r.referenceFeatureCount,r.matches,r.inliers,r.coverage,r.medianError,r.p95Error,r.analysisMilliseconds);
    for (double c:r.corners) std::printf(" %.4f",c); std::puts("");
}
static BNTResult process(BNTTracker *tracker,const Image &image) {
    return BNTProcess(tracker,image.pixels.data(),image.width,image.height,image.stride());
}
static std::vector<uint8_t> mask(const Image &image,bool screenshot=false,double personX=.30,double personY=.58) {
    std::vector<uint8_t> result(size_t(image.width)*image.height,0);
    for (int y=0;y<image.height;++y) for (int x=0;x<image.width;++x) {
        const uint8_t *p=&image.pixels[size_t(y)*image.stride()+x*4];
        if ((x<image.width*personX&&y>image.height*personY)||
            (screenshot&&p[2]>140&&p[2]>p[1]*1.6&&p[2]>p[0]*1.6)) result[size_t(y)*image.width+x]=255;
    }
    return result;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc<4) { std::fprintf(stderr,"usage: NativeTrackerChecks reference.png older.png latest.png [rawA.png rawB.png]\n"); return 2; }
        const Image reference=load(argv[1]),older=load(argv[2]),latest=load(argv[3]);
        const double full[8]={0,0,1,0,1,1,0,1};
        BNTTracker *tracker=BNTCreate(); expect(tracker,"create");
        expect(process(tracker,reference).rejectionCode==BNT_REJECTION_UNSEEDED,"unseeded unavailable");
        const auto excluded=mask(reference);
        const auto seed=BNTSeed(tracker,reference.pixels.data(),reference.width,reference.height,reference.stride(),full,excluded.data(),reference.width);
        report("reference seed",seed); expect(seed.status==1,"real reference seeds");
        const auto identity=process(tracker,reference);
        report("identity",identity); expect(identity.status==1,"exact reference identity");
        double identityError=0; for (int i=0;i<8;++i) identityError=std::max(identityError,std::abs(identity.corners[i]-full[i]));
        expect(identityError<.005,"identity corners within0.5%");
        auto first=process(tracker,older); report("reference to older",first); expect(first.status==1,"real older board accepted");
        auto last=process(tracker,latest); report("reference to latest",last); expect(last.status==1,"real latest board accepted");
        expect(last.corners[0]<.15&&last.corners[1]<.15&&last.corners[2]>.90,"latest corners exclude observed sheared false positive");
        expect(last.corners[3]-last.corners[1]>-.04,"latest top edge must not acquire observed false shear");
        Image blank=latest; std::fill(blank.pixels.begin(),blank.pixels.end(),240);
        auto absent=process(tracker,blank); expect(absent.status==0,"complete occlusion unavailable");
        expect(std::all_of(std::begin(absent.corners),std::end(absent.corners),[](double p){return p==0;}),"failure withdraws every corner");
        auto recovered=process(tracker,latest); expect(recovered.status==1,"original board returns without recalibration");
        double drift=0; for (int i=0;i<8;++i) drift=std::max(drift,std::abs(last.corners[i]-recovered.corners[i]));
        expect(drift<1e-8,"immutable reference cannot drift after rejection");
        Image noise=latest; uint32_t rng=123;
        for (size_t i=0;i<noise.pixels.size();i+=4) { rng=rng*1664525u+1013904223u; noise.pixels[i]=noise.pixels[i+1]=noise.pixels[i+2]=uint8_t(rng>>24); noise.pixels[i+3]=255; }
        expect(process(tracker,noise).status==0,"unrelated texture unavailable");
        Image fragment=reference; std::fill(fragment.pixels.begin(),fragment.pixels.end(),240);
        for (int y=int(reference.height*.35);y<int(reference.height*.6);++y) for (int x=int(reference.width*.4);x<int(reference.width*.65);++x)
            std::copy_n(&reference.pixels[size_t(y)*reference.stride()+x*4],4,&fragment.pixels[size_t(y)*fragment.stride()+x*4]);
        auto local=process(tracker,fragment); report("small reference fragment",local); expect(local.status==0,"local matching text cannot justify entire board");
        const auto oldMask=mask(older,true);
        auto oldSeed=BNTSeed(tracker,older.pixels.data(),older.width,older.height,older.stride(),full,oldMask.data(),older.width);
        expect(oldSeed.status==1,"older real view seeds with UI/person excluded");
        auto pair=process(tracker,latest); report("older to latest",pair); expect(pair.status==1,"actual photograph pair accepted");
        std::vector<uint8_t> excludeAll(size_t(reference.width)*reference.height,255);
        expect(BNTSeed(tracker,reference.pixels.data(),reference.width,reference.height,reference.stride(),full,excludeAll.data(),reference.width).status==0,"fully excluded calibration fails");
        expect(process(tracker,reference).status==0,"failed seed clears previous reference");
        if (argc>=6) {
            const Image rawA=load(argv[4]),rawB=load(argv[5]); const auto rawMask=mask(rawA,false,.40,.40);
            const double board[8]={.12,.139,.948,.171,.971,.926,.078,.875};
            expect(BNTSeed(tracker,rawA.pixels.data(),rawA.width,rawA.height,rawA.stride(),board,rawMask.data(),rawA.width).status==1,"raw camera photo with person mask seeds");
            auto stationary=process(tracker,rawB); report("stationary board moving person",stationary); expect(stationary.status==1,"person movement does not move stationary board");
            double error=0; for (int i=0;i<8;++i) error=std::max(error,std::abs(stationary.corners[i]-board[i]));
            expect(error<.01,"moving person preserves board corners within1%");
            Image person=rawA; std::fill(person.pixels.begin(),person.pixels.end(),240);
            for (int y=int(rawA.height*.4);y<rawA.height;++y) std::copy_n(&rawA.pixels[size_t(y)*rawA.stride()],int(rawA.width*.4)*4,&person.pixels[size_t(y)*person.stride()]);
            expect(process(tracker,person).status==0,"excluded person alone cannot be reacquired as board");
        }
        BNTReset(tracker); expect(process(tracker,latest).status==0,"reset withdraws reference");
        expect(BNTProcess(tracker,nullptr,100,100,400).rejectionCode==BNT_REJECTION_ARGUMENT,"null frame safely rejected");
        BNTDestroy(tracker);
        std::printf("PASS: %d native real-photo, geometry, mask, immutable-reference and negative checks. Timings are instrumented diagnostics.\n",checks);
    }
}
