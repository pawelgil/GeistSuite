#import "Provenance.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>

CFStringRef const kGeistCamProvenanceKey = CFSTR("GeistCamProvenance");

// Triple-tag at delivery so the marker survives common app-side transforms:
// the CMSampleBuffer tag survives CMSampleBufferCreateCopy, the CVPixelBuffer
// tag survives sample-buffer rebuild around the same pixel buffer, and the
// IOSurface tag survives Metal/CoreImage pipelines that preserve the surface.
void tagSampleBufferProvenance(CMSampleBufferRef sb) {
    if (!sb) return;
    CMSetAttachment(sb, kGeistCamProvenanceKey, kCFBooleanTrue,
                    kCMAttachmentMode_ShouldPropagate);

    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (ib) {
        CVBufferSetAttachment(ib, kGeistCamProvenanceKey, kCFBooleanTrue,
                              kCVAttachmentMode_ShouldPropagate);
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(ib);
        if (surface) {
            IOSurfaceSetValue(surface, kGeistCamProvenanceKey, kCFBooleanTrue);
        }
    }
}

BOOL sampleBufferHasOurProvenance(CMSampleBufferRef sb) {
    if (!sb) return NO;
    if (CMGetAttachment(sb, kGeistCamProvenanceKey, NULL)) return YES;
    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (!ib) return NO;
    if (CVBufferGetAttachment(ib, kGeistCamProvenanceKey, NULL)) return YES;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(ib);
    if (!surface) return NO;
    CFTypeRef val = IOSurfaceCopyValue(surface, kGeistCamProvenanceKey);
    if (val) {
        CFRelease(val);
        return YES;
    }
    return NO;
}
