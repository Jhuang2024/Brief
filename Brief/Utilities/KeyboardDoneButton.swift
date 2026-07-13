import SwiftUI

extension View {
    /// Adds a "Done" button above the keyboard that resigns first responder,
    /// so every text field in the app has a way to dismiss the keyboard
    /// without needing a Return key or a tap elsewhere.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                }
            }
        }
    }
}
