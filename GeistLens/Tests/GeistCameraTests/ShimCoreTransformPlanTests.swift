import Testing
import GeistCameraShimCore

@Suite("geistcam_computeTransformPlan")
struct GeistCamComputeTransformPlanTests {
    @Test func identity_inputMatchesTarget_returnsIdentity() {
        let plan = geistcam_computeTransformPlan(1920, 1080, 1920, 1080, 0)
        #expect(plan.isIdentity == true)
        #expect(plan.outputW == 1920)
        #expect(plan.outputH == 1080)
        #expect(plan.scale == 1.0)
    }

    @Test func portrait_swapsTargetDims() {
        let plan = geistcam_computeTransformPlan(1920, 1080, 1920, 1080, 90)
        #expect(plan.outputW == 1080)
        #expect(plan.outputH == 1920)
        #expect(plan.isIdentity == false)
    }

    @Test func portrait270_alsoSwapsTargetDims() {
        let plan = geistcam_computeTransformPlan(1920, 1080, 1920, 1080, 270)
        #expect(plan.outputW == 1080)
        #expect(plan.outputH == 1920)
    }

    @Test func upscale_smallerInputToLargerTarget() {
        // 1280×720 source, 1920×1080 target, both 16:9. No crop; scale 1.5.
        let plan = geistcam_computeTransformPlan(1280, 720, 1920, 1080, 0)
        #expect(plan.outputW == 1920)
        #expect(plan.outputH == 1080)
        #expect(plan.sourceCrop.w == 1280)
        #expect(plan.sourceCrop.h == 720)
        #expect(abs(plan.scale - 1.5) < 0.0001)
    }

    @Test func centerCrop_portraitSourceLandscapeTarget_cropsTopAndBottom() {
        // 1080×1920 source (9:16), 1920×1080 target (16:9). Source is taller —
        // crop top/bottom to make a 16:9 strip, then scale.
        let plan = geistcam_computeTransformPlan(1080, 1920, 1920, 1080, 0)
        #expect(plan.outputW == 1920)
        #expect(plan.outputH == 1080)
        #expect(plan.sourceCrop.w == 1080)
        // cropH = 1080 / (16/9) = 607.5 → 608
        #expect(plan.sourceCrop.h == 608)
        #expect(plan.sourceCrop.x == 0)
        #expect(plan.sourceCrop.y == (1920 - 608) / 2)
    }

    @Test func centerCrop_landscapeSourcePortraitTarget_cropsSides() {
        // 1920×1080 source (16:9), portrait orientation makes target 1080×1920.
        // Source is wider — crop sides.
        let plan = geistcam_computeTransformPlan(1920, 1080, 1920, 1080, 90)
        #expect(plan.outputW == 1080)
        #expect(plan.outputH == 1920)
        // cropW = 1080 * (1080/1920) = 607.5 → 608
        #expect(plan.sourceCrop.w == 608)
        #expect(plan.sourceCrop.h == 1080)
        #expect(plan.sourceCrop.x == (1920 - 608) / 2)
    }

    @Test func nilTarget_fallsBackToInputDims() {
        let plan = geistcam_computeTransformPlan(1280, 720, 0, 0, 0)
        #expect(plan.outputW == 1280)
        #expect(plan.outputH == 720)
        #expect(plan.isIdentity == true)
    }

    @Test func degenerateInput_returnsIdentityZero() {
        let plan = geistcam_computeTransformPlan(0, 0, 1920, 1080, 0)
        #expect(plan.outputW == 0)
        #expect(plan.outputH == 0)
        #expect(plan.isIdentity == true)
    }

    @Test func rotation180_keepsLandscapeDims() {
        // 0° and 180° both produce landscape output dims; pixel rotation for
        // 180° is the caller's responsibility (not part of the plan).
        let plan = geistcam_computeTransformPlan(1920, 1080, 1920, 1080, 180)
        #expect(plan.outputW == 1920)
        #expect(plan.outputH == 1080)
        #expect(plan.isIdentity == true)
    }

    @Test func equalAspect_differentDims_isNotIdentity() {
        // 640×360 → 1920×1080: both 16:9 but dim-different. No crop, scale 3.
        let plan = geistcam_computeTransformPlan(640, 360, 1920, 1080, 0)
        #expect(plan.isIdentity == false)
        #expect(plan.sourceCrop.w == 640)
        #expect(plan.sourceCrop.h == 360)
        #expect(plan.sourceCrop.x == 0)
        #expect(plan.sourceCrop.y == 0)
        #expect(abs(plan.scale - 3.0) < 0.0001)
    }

    @Test func oddInputDims_centerCropDistributesAsymmetrically() {
        // 1921×1080 → 1920×1080: nearly equal, but inputAR > outputAR by a hair.
        // Branch picks crop width based on inH * outputAR = 1080 * (16/9) = 1920.
        // So sourceCrop.w == 1920, x = (1921 - 1920)/2 = 0 (integer division).
        let plan = geistcam_computeTransformPlan(1921, 1080, 1920, 1080, 0)
        #expect(plan.sourceCrop.w == 1920)
        #expect(plan.sourceCrop.h == 1080)
        #expect(plan.sourceCrop.x == 0)
        #expect(plan.sourceCrop.y == 0)
    }
}
