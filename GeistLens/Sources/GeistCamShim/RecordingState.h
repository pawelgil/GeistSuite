#import <Foundation/Foundation.h>
@class AVAssetWriter;
@class GeistCamMovieRecording;

// Per-session recording state. Updated by MovieFileOutput swizzles and by
// AVAssetWriter tagging detection; collapses both into one boolean and sends
// RECORDING_STATE on transitions.

void recordingMovieOutputStarted(GeistCamMovieRecording *rec);
void recordingMovieOutputStopped(GeistCamMovieRecording *rec);

void recordingAssetWriterFlagged(AVAssetWriter *writer);
void recordingAssetWriterTerminated(AVAssetWriter *writer);

BOOL recordingIsActive(void);

// Re-send current state on new feeder connection so the lib syncs up.
void recordingResyncForNewFeeder(void);
