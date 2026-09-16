//
//  PrefSubViewController.swift
//  iina
//
//  Created by lhc on 27/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

@objcMembers
class PrefSubViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefSubViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.subtitle", comment: "Subtitles")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("captions.bubble", fallbackImage: "pref_sub")
  }

  override var sectionViews: [NSView] {
    return [sectionAutoLoadView, sectionASSView, sectionTextSubView, sectionPositionView, sectionOtherView]
  }

  @IBOutlet var sectionAutoLoadView: NSView!
  @IBOutlet var sectionASSView: NSView!
  @IBOutlet var sectionTextSubView: NSView!
  @IBOutlet var sectionPositionView: NSView!
  @IBOutlet var sectionOtherView: NSView!

  @IBOutlet weak var subLangTokenView: LanguageTokenField!
  @IBOutlet weak var defaultEncodingList: NSPopUpButton!

  @IBOutlet var subColorWell: NSColorWell!
  @IBOutlet var subBackgroundColorWell: NSColorWell!
  @IBOutlet var subBorderColorWell: NSColorWell!
  @IBOutlet var subShadowColorWell: NSColorWell!

  @IBOutlet weak var subOverrideLevelSlider: NSSlider!
  @IBOutlet weak var subOverrideLevelSegmentedControl: NSSegmentedControl!
  @IBOutlet weak var subOverrideLevelText: NSTextField!
  @IBOutlet weak var subOverrideLevelDescriptiveText: NSTextField!

  override func viewDidLoad() {
    super.viewDidLoad()

#if MACOS_13_AVAILABLE
    if #available(macOS 13.0, *) {
      [subColorWell, subBackgroundColorWell, subBorderColorWell, subShadowColorWell].forEach {
        $0.colorWellStyle = .expanded
      }
    }
#endif

    let defaultEncoding = Preference.string(for: .defaultEncoding)
    for encoding in AppData.encodings {
      defaultEncodingList.addItem(withTitle: encoding.title)
      let lastItem = defaultEncodingList.lastItem!
      lastItem.representedObject = encoding.code
      if encoding.code == defaultEncoding ?? "auto" {
        defaultEncodingList.select(lastItem)
      }
    }

    defaultEncodingList.menu?.insertItem(NSMenuItem.separator(), at: 1)
    subLangTokenView.commaSeparatedValues = Preference.string(for: .subLang) ?? ""
  }

  @IBAction func chooseSubFontAction(_ sender: AnyObject) {
    let subFont = Preference.string(for: .subTextFont)
    Utility.quickFontPickerWindow(selecting: subFont) { font in
      Preference.set(font, for: .subTextFont)
    }
  }

  @IBAction func changeDefaultEncoding(_ sender: NSPopUpButton) {
    Preference.set(sender.selectedItem!.representedObject!, for: .defaultEncoding)
    PlayerCore.active.setSubEncoding((sender.selectedItem?.representedObject as? String) ?? "auto")
    PlayerCore.active.reloadAllSubs()
  }

  @IBAction func subOverrideHelpBtnAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: "https://mpv.io/manual/stable/#options-sub-ass-override")!)
  }

  @IBAction func preferredLanguageAction(_ sender: LanguageTokenField) {
    let csv = sender.commaSeparatedValues
    if Preference.string(for: .subLang) != csv {
      Logger.log("Saving \(Preference.Key.subLang.rawValue): \"\(csv)\"", level: .verbose)
      Preference.set(csv, for: .subLang)
    }
  }

  @IBAction func subOverrideLevelSegmentedControlAction(_ sender: NSSegmentedControl) {
    let keyPath = sender.selectedSegment == 0 ? PK.subOverrideLevel.rawValue : PK.secondarySubOverrideLevel.rawValue
    subOverrideLevelSlider.bind(.value, to: UserDefaults.standard, withKeyPath: keyPath, options: [.valueTransformer: ASSOverrideLevelValueTransformer()])
    subOverrideLevelText.bind(.value, to: UserDefaults.standard, withKeyPath: keyPath, options: [.valueTransformer: ASSOverrideLevelTextTransformer()])
    subOverrideLevelDescriptiveText.bind(.value, to: UserDefaults.standard, withKeyPath: keyPath, options: [.valueTransformer: ASSOverrideLevelDescriptiveTextTransformer()])
  }
}

// MARK: - Transformers

class ASSOverrideLevelTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return false
  }

  static override func transformedValueClass() -> AnyClass {
    return NSString.self
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let num = value as? NSNumber,
          let level = Preference.SubOverrideLevel(rawValue: num.intValue) else { return nil }
    return level.string
  }
}

@objc(ASSOverrideLevelTextTransformer) class ASSOverrideLevelTextTransformer: ASSOverrideLevelTransformer {
  override func transformedValue(_ value: Any?) -> Any? {
    guard let level = super.transformedValue(value) as? String else { return nil }
    return NSLocalizedString("preference.sub_override_level." + level, comment: level)
  }
}


@objc(ASSOverrideLevelDescriptiveTextTransformer) class ASSOverrideLevelDescriptiveTextTransformer: ASSOverrideLevelTransformer {
  override func transformedValue(_ value: Any?) -> Any? {
    guard let level = super.transformedValue(value) as? String else { return nil }
    return NSLocalizedString("preference.sub_override_level.descriptive_text." + level, comment: level)
  }
}

/// Transform a raw `SubOverrideLevel` enum value into a slider value.
///
/// Normally there is a 1 to 1 mapping between an enum value and a slider value. However this is not true for `SubOverrideLevel`.
/// Originally the only supported values for the `Override level` setting were `yes`, `force` and `strip`. Then `scale` and
/// `no` were added. The order for the slider now _must_ be `no`, `yes`, `scale`, `force` and `strip`. But to preserve
/// backward compatibility with enum values stored in user's settings `scale` and `no` were added to the end of the enumeration,
/// thus requiring a transformation between the slider and enum values as shown in this table:
///
/// | Slider | Raw | Enum |
/// | --- | --- | --- |
/// | 0 | 4 | no |
/// | 1 | 0 | yes |
/// | 2 | 3 | scale |
/// | 3 | 1 | force |
/// | 4 | 2 | strip |
@objc(ASSOverrideLevelValueTransformer) class ASSOverrideLevelValueTransformer: ValueTransformer {

  private static let enumToSlider: [NSNumber: NSNumber] = [0: 1, 1: 3, 2: 4, 3: 2, 4: 0]

  private static let sliderToEnum: [NSNumber: NSNumber] = {
    var result: [NSNumber: NSNumber] = [:]
    for (raw, slider) in enumToSlider { result[slider] = raw }
    return result
  }()

  override class func allowsReverseTransformation() -> Bool { true }

  override func reverseTransformedValue(_ value: Any?) -> Any? {
    guard let value = toNumber(value) else { return nil }
    return ASSOverrideLevelValueTransformer.sliderToEnum[value]
  }

  override func transformedValue(_ value: Any?) -> Any? {
    guard let value = toNumber(value) else { return nil }
    return ASSOverrideLevelValueTransformer.enumToSlider[value]
  }

  override class func transformedValueClass() -> AnyClass { NSNumber.self }

  private func toNumber(_ value: Any?) -> NSNumber? {
    guard let value = value as? NSNumber else {
      guard let value = value as? NSString else { return nil }
      return value.integerValue as NSNumber
    }
    return value
  }
}

@objc(MPVColorStringTransformer) class MPVColorStringTransformer: ValueTransformer {

  static override func allowsReverseTransformation() -> Bool {
    return true
  }

  static override func transformedValueClass() -> AnyClass {
    return NSString.self
  }

  // Serializes an NSColor to an mpv-recognized string
  override func transformedValue(_ value: Any?) -> Any? {
    guard let mpvColorString = value as? NSString else { return nil }
    return NSColor(mpvColorString: String(mpvColorString))
  }

  override func reverseTransformedValue(_ value: Any?) -> Any? {
    guard let color = value as? NSColor else { return nil }
    return color.usingColorSpace(.deviceRGB)!.mpvColorString
  }
}
