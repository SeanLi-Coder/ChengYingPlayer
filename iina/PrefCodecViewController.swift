//
//  PrefCodecViewController.swift
//  iina
//
//  Created by lhc on 27/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

@objcMembers
class PrefCodecViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefCodecViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.video_audio", comment: "Codec")
  }

  var preferenceTabImage: NSImage {
    return makeSymbol("play.rectangle.on.rectangle", fallbackImage: "pref_av")
  }

  override var sectionViews: [NSView] {
    return [sectionVideoView, sectionAudioView]
  }

  @IBOutlet var sectionVideoView: NSView!
  @IBOutlet var sectionAudioView: NSView!
  @IBOutlet weak var hwdecDescriptionTextField: NSTextField!
  @IBOutlet weak var audioLangTokenField: LanguageTokenField!
  @IBOutlet weak var audioDevicePopUp: NSPopUpButton!
  @IBOutlet weak var enableToneMappingBtn: NSButton!
  @IBOutlet weak var toneMappingTargetPeakTextField: NSTextField!
  @IBOutlet weak var toneMappingAlgorithmPopUpBtn: NSPopUpButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    audioLangTokenField.commaSeparatedValues = Preference.string(for: .audioLanguage) ?? ""
    updateHwdecDescription()
    updateToneMappingUI()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    updateAudioDevicePopUp()
  }

  @IBAction func audioDeviceAction(_ sender: Any) {
    let device = audioDevicePopUp.selectedItem!.representedObject as! MPVAudioDevice
    Preference.set(device.name, for: .audioDevice)
    Preference.set(device.desc, for: .audioDeviceDesc)
  }

  @IBAction func hwdecAction(_ sender: AnyObject) {
    updateHwdecDescription()
  }

  @IBAction func preferredLanguageAction(_ sender: LanguageTokenField) {
    let csv = sender.commaSeparatedValues
    if Preference.string(for: .audioLanguage) != csv {
      Logger.log("Saving \(Preference.Key.audioLanguage.rawValue): \"\(csv)\"", level: .verbose)
      Preference.set(csv, for: .audioLanguage)
    }
  }

  /// Refresh Core Audio devices without rewriting saved preferences from older builds.
  private func updateAudioDevicePopUp() {
    audioDevicePopUp.removeAllItems()
    let audioDevices = PlayerCore.active.getAudioDevices()
    let audioDevice = Preference.effectiveAudioDeviceName
    var selected = false
    audioDevices.forEach { device in
      audioDevicePopUp.addItem(withTitle: device.description)
      audioDevicePopUp.lastItem!.representedObject = device
      if device.name == audioDevice {
        audioDevicePopUp.select(audioDevicePopUp.lastItem!)
        selected = true
      }
    }
    if !selected {
      let device = MPVAudioDevice(desc: Preference.string(for: .audioDeviceDesc)!,
                                  name: audioDevice, isMissing: true)
      audioDevicePopUp.addItem(withTitle: String(describing: device))
      audioDevicePopUp.lastItem!.representedObject = device
      audioDevicePopUp.select(audioDevicePopUp.lastItem!)
    }
  }

  private func updateHwdecDescription() {
    let hwdec: Preference.HardwareDecoderOption = Preference.enum(for: .hardwareDecoder)
    hwdecDescriptionTextField.stringValue = hwdec.localizedDescription
  }

  private func updateToneMappingUI() {
    toneMappingTargetPeakTextField.integerValue = Preference.integer(for: .toneMappingTargetPeak)
  }

  @IBAction func toneMappingTargetPeakAction(_ sender: NSTextField) {
    defer {
      updateToneMappingUI()
    }
    let newValue = sender.integerValue
    let isValueValid = newValue == 0 || (newValue >= 10 && newValue <= 10000)
    guard isValueValid else {
      Utility.showAlert("target_peak.bad_value", arguments: [String(newValue)], sheetWindow: view.window)
      sender.integerValue = Preference.integer(for: .toneMappingTargetPeak)
      return
    }
    Preference.set(newValue, for: .toneMappingTargetPeak)
  }

  @IBAction func toneMappingHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.toneMappingHelpLink)!)
  }

  @IBAction func targetPeakHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.targetPeakHelpLink)!)
  }

  @IBAction func algorithmHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.algorithmHelpLink)!)
  }
}
