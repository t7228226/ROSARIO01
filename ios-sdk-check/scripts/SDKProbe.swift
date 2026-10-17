import Foundation
import UIKit
import SwiftUI

@MainActor
public func sdkProbe() -> Color {
    _ = ProcessInfo.processInfo.operatingSystemVersion
    return Color(UIColor.systemBlue)
}
