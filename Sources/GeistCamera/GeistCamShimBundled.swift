import Foundation

public enum GeistCamShimBundled {
    public static var dylibPath: String {
        guard let path = Bundle.module.path(forResource: "GeistCamShim", ofType: "dylib") else {
            fatalError("GeistCamShim.dylib missing from GeistCam resources — build plugin did not run")
        }
        return path
    }
}
