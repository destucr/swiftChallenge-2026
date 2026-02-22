import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "black_bar_playback" asset catalog image resource.
    static let blackBarPlayback = DeveloperToolsSupport.ImageResource(name: "black_bar_playback", bundle: resourceBundle)

    /// The "button_disable" asset catalog image resource.
    static let buttonDisable = DeveloperToolsSupport.ImageResource(name: "button_disable", bundle: resourceBundle)

    /// The "button_enable" asset catalog image resource.
    static let buttonEnable = DeveloperToolsSupport.ImageResource(name: "button_enable", bundle: resourceBundle)

    /// The "display_off" asset catalog image resource.
    static let displayOff = DeveloperToolsSupport.ImageResource(name: "display_off", bundle: resourceBundle)

    /// The "display_on" asset catalog image resource.
    static let displayOn = DeveloperToolsSupport.ImageResource(name: "display_on", bundle: resourceBundle)

    /// The "ic_next" asset catalog image resource.
    static let icNext = DeveloperToolsSupport.ImageResource(name: "ic_next", bundle: resourceBundle)

    /// The "ic_pause" asset catalog image resource.
    static let icPause = DeveloperToolsSupport.ImageResource(name: "ic_pause", bundle: resourceBundle)

    /// The "ic_play" asset catalog image resource.
    static let icPlay = DeveloperToolsSupport.ImageResource(name: "ic_play", bundle: resourceBundle)

    /// The "ic_previous" asset catalog image resource.
    static let icPrevious = DeveloperToolsSupport.ImageResource(name: "ic_previous", bundle: resourceBundle)

    /// The "ic_replay" asset catalog image resource.
    static let icReplay = DeveloperToolsSupport.ImageResource(name: "ic_replay", bundle: resourceBundle)

    /// The "ic_stop" asset catalog image resource.
    static let icStop = DeveloperToolsSupport.ImageResource(name: "ic_stop", bundle: resourceBundle)

    /// The "knob_black_ring" asset catalog image resource.
    static let knobBlackRing = DeveloperToolsSupport.ImageResource(name: "knob_black_ring", bundle: resourceBundle)

    /// The "knob_control" asset catalog image resource.
    static let knobControl = DeveloperToolsSupport.ImageResource(name: "knob_control", bundle: resourceBundle)

    /// The "knob_shadow" asset catalog image resource.
    static let knobShadow = DeveloperToolsSupport.ImageResource(name: "knob_shadow", bundle: resourceBundle)

    /// The "speaker" asset catalog image resource.
    static let speaker = DeveloperToolsSupport.ImageResource(name: "speaker", bundle: resourceBundle)

    /// The "volume_indicator_line" asset catalog image resource.
    static let volumeIndicatorLine = DeveloperToolsSupport.ImageResource(name: "volume_indicator_line", bundle: resourceBundle)

    /// The "volume_knob" asset catalog image resource.
    static let volumeKnob = DeveloperToolsSupport.ImageResource(name: "volume_knob", bundle: resourceBundle)

}

