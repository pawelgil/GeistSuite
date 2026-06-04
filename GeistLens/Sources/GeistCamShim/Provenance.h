#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

extern CFStringRef const kGeistCamProvenanceKey;

void tagSampleBufferProvenance(CMSampleBufferRef sb);
BOOL sampleBufferHasOurProvenance(CMSampleBufferRef sb);
