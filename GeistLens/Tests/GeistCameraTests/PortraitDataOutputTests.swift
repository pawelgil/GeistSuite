import CoreImage
import GeistCameraShimCore
import Testing

struct PortraitDataOutputTests {
    @Test(arguments: [
        (angle: Int32(0), width: 60, height: 40, colors: [4, 1, 3, 2]),
        (angle: Int32(90), width: 40, height: 60, colors: [1, 2, 4, 3]),
        (angle: Int32(180), width: 60, height: 40, colors: [2, 3, 1, 4]),
        (angle: Int32(270), width: 40, height: 60, colors: [3, 4, 2, 1]),
    ])
    func dataOutput_ConnectionAngle_RotatesPixelsAndDimensions(
        angle: Int32, width: Int, height: Int, colors: [Int]
    ) {
        let plan = geistcam_computePortraitDataOutputPlan(40, 60, 60, 40, angle)

        let result = geistcam_imageByApplyingTransformPlan(makeQuadrants(), plan, false, 1)

        #expect(result.extent == CGRect(x: 0, y: 0, width: width, height: height))
        #expect(cornerColors(result) == colors)
        #expect(plan.isIdentity == (angle == 90))
    }

    @Test func dataOutput_MirroredSource_RestoresHorizontalMirror() {
        let plan = geistcam_computePortraitDataOutputPlan(40, 60, 60, 40, 0)

        let result = geistcam_imageByApplyingTransformPlan(makeQuadrants(), plan, true, 1).oriented(.right)

        #expect(cornerColors(result) == [2, 1, 3, 4])
    }

    @Test func dataOutput_UnmatchedAspectRatio_CropsInSensorSpace() {
        let plan = geistcam_computePortraitDataOutputPlan(832, 1088, 1280, 720, 0)

        #expect(plan.outputW == 1280 && plan.outputH == 720)
        #expect(plan.sourceCrop.x == 0 && plan.sourceCrop.y == 110)
        #expect(plan.sourceCrop.w == 1088 && plan.sourceCrop.h == 612)
        #expect(plan.pixelRotationDegrees == 270)
    }

    @Test(arguments: [Int32(0), 90])
    func dataOutput_MissingFormat_UsesSensorDimensions(angle: Int32) {
        let plan = geistcam_computePortraitDataOutputPlan(40, 60, 0, 0, angle)

        #expect(plan.outputW == (angle == 0 ? 60 : 40))
        #expect(plan.outputH == (angle == 0 ? 40 : 60))
        #expect(plan.scale == 1)
    }

    @Test func coordinator_Portrait_RestoresUprightSource() {
        let angle = geistcam_portraitCaptureRotationDegrees()
        let plan = geistcam_computePortraitDataOutputPlan(40, 60, 60, 40, angle)

        #expect(angle == 90)
        #expect(cornerColors(geistcam_imageByApplyingTransformPlan(makeQuadrants(), plan, false, 1)) == [1, 2, 4, 3])
    }

    @Test func presentation_Portrait_RemainsUpright() {
        let plan = geistcam_computeTransformPlan(40, 60, 60, 40, 90)

        let result = geistcam_imageByApplyingTransformPlan(makeQuadrants(), plan, false, 1)

        #expect(result.extent == CGRect(x: 0, y: 0, width: 40, height: 60))
        #expect(cornerColors(result) == [1, 2, 4, 3])
    }

    @Test func dataOutput_Zoom_CropsBeforeSensorRotation() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 10, y: 15, width: 20, height: 30))
            .composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 60)))
        let plan = geistcam_computePortraitDataOutputPlan(40, 60, 60, 40, 0)

        let result = geistcam_imageByApplyingTransformPlan(source, plan, false, 2)

        #expect(cornerColors(result) == [1, 1, 1, 1])
    }

    private func makeQuadrants() -> CIImage {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 30))
        let green = CIImage(color: .green).cropped(to: CGRect(x: 20, y: 0, width: 20, height: 30))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 30, width: 20, height: 30))
        let yellow = CIImage(color: .yellow).cropped(to: CGRect(x: 20, y: 30, width: 20, height: 30))
        return red.composited(over: green).composited(over: blue).composited(over: yellow)
    }

    private func cornerColors(_ image: CIImage) -> [Int] {
        [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
            var bytes = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &bytes, rowBytes: 4,
                               bounds: CGRect(x: image.extent.width * x, y: image.extent.height * y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (bytes[0] > 128 ? 1 : 0) + (bytes[1] > 128 ? 2 : 0) + (bytes[2] > 128 ? 4 : 0)
        }
    }
}
