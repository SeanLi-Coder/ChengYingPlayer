import AppKit
import Sparkle

/// Observe the real driver's state at Sparkle callback boundaries, never by polling.
@MainActor
final class FixtureObservedUserDriver: NSObject, SPUUserDriver {
  let driver: AppUpdateUserDriver
  var didObserve: ((AppUpdateUserDriver) -> Void)?

  init(driver: AppUpdateUserDriver) { self.driver = driver }

  func observe() { didObserve?(driver) }

  private func forward(_ callback: () -> Void) {
    callback()
    observe()
  }

  // Sparkle replies may reenter its driver or terminate the process synchronously.
  private func observingReply<Value>(_ reply: @escaping (Value) -> Void) -> (Value) -> Void {
    { [weak self] value in
      self?.observe()
      reply(value)
    }
  }

  private func observingAcknowledgement(_ reply: @escaping () -> Void) -> () -> Void {
    { [weak self] in
      self?.observe()
      reply()
    }
  }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    forward { driver.show(request, reply: observingReply(reply)) }
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    forward { driver.showUserInitiatedUpdateCheck(cancellation: cancellation) }
  }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    forward { driver.showUpdateFound(with: appcastItem, state: state, reply: observingReply(reply)) }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    forward { driver.showUpdateReleaseNotes(with: downloadData) }
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
    forward { driver.showUpdateReleaseNotesFailedToDownloadWithError(error) }
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    forward { driver.showUpdateNotFoundWithError(error, acknowledgement: observingAcknowledgement(acknowledgement)) }
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    forward { driver.showUpdaterError(error, acknowledgement: observingAcknowledgement(acknowledgement)) }
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    forward { driver.showDownloadInitiated(cancellation: cancellation) }
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    forward { driver.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    forward { driver.showDownloadDidReceiveData(ofLength: length) }
  }

  func showDownloadDidStartExtractingUpdate() {
    forward { driver.showDownloadDidStartExtractingUpdate() }
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    forward { driver.showExtractionReceivedProgress(progress) }
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    forward { driver.showReady(toInstallAndRelaunch: observingReply(reply)) }
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    forward {
      driver.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                  retryTerminatingApplication: retryTerminatingApplication)
    }
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    forward { driver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: observingAcknowledgement(acknowledgement)) }
  }

  func dismissUpdateInstallation() { forward { driver.dismissUpdateInstallation() } }
  func showUpdateInFocus() { forward { driver.showUpdateInFocus() } }
}
