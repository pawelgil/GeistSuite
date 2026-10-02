import Foundation

@available(macOS 14.0, macCatalyst 18.2, iOS 27.0, visionOS 27.0, tvOS 27.0, *)
public struct SCContentSharingPickerConfiguration {
    // MARK: Properties

    fileprivate var storage: __SCContentSharingPickerConfiguration<AnyObject>

    // MARK: Computed Properties

    @available(macOS 14.0, macCatalyst 18.2, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    @available(tvOS, unavailable)
    public var allowedPickerModes: SCContentSharingPickerMode {
        get { storage.allowedPickerModes }
        set { storage.allowedPickerModes = newValue }
    }

    @available(macOS 14.0, macCatalyst 18.2, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    @available(tvOS, unavailable)
    public var excludedWindowIDs: [Int] {
        get { storage.excludedWindowIDs.map(\.intValue) }
        set { storage.excludedWindowIDs = newValue.map(NSNumber.init(value:)) }
    }

    @available(macOS 14.0, macCatalyst 18.2, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    @available(tvOS, unavailable)
    public var excludedBundleIDs: [String] {
        get { storage.excludedBundleIDs }
        set { storage.excludedBundleIDs = newValue }
    }

    @available(macOS 14.0, macCatalyst 18.2, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    @available(tvOS, unavailable)
    public var allowsChangingSelectedContent: Bool {
        get { storage.allowsChangingSelectedContent }
        set { storage.allowsChangingSelectedContent = newValue }
    }

    @available(iOS 27.0, visionOS 27.0, *)
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    @available(tvOS, unavailable)
    public var showsMicrophoneControl: Bool {
        get { storage.showsMicrophoneControl }
        set { storage.showsMicrophoneControl = newValue }
    }

    @available(iOS 27.0, *)
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    @available(visionOS, unavailable)
    public var showsCameraControl: Bool {
        get { storage.showsCameraControl }
        set { storage.showsCameraControl = newValue }
    }

    // MARK: Lifecycle

    public init() {
        storage = __SCContentSharingPickerConfiguration()
    }

    fileprivate init(storage: __SCContentSharingPickerConfiguration<AnyObject>) {
        self.storage = storage
    }
}

@available(macOS 14.0, macCatalyst 18.2, iOS 27.0, visionOS 27.0, tvOS 27.0, *)
public extension SCContentSharingPicker {
    var configuration: SCContentSharingPickerConfiguration? {
        get { SCContentSharingPickerConfiguration(storage: __defaultConfiguration) }
        set {
            __defaultConfiguration = newValue?.storage
                ?? __SCContentSharingPickerConfiguration()
        }
    }

    var defaultConfiguration: SCContentSharingPickerConfiguration {
        get { SCContentSharingPickerConfiguration(storage: __defaultConfiguration) }
        set { __defaultConfiguration = newValue.storage }
    }

    @available(macOS 14.0, macCatalyst 18.2, *)
    @available(iOS, unavailable)
    @available(visionOS, unavailable)
    @available(tvOS, unavailable)
    var maximumStreamCount: Int? {
        get { __maximumStreamCount?.intValue }
        set { __maximumStreamCount = newValue.map(NSNumber.init(value:)) }
    }

    func setConfiguration(
        _ configuration: SCContentSharingPickerConfiguration?,
        for stream: SCStream
    ) {
        __setConfiguration(configuration?.storage, for: stream)
    }
}
