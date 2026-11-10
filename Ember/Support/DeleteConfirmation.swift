import SwiftUI

extension View {
    /// The one way this app asks before something is gone for good: a title saying what's about
    /// to go, and a red Delete.
    func deleteConfirmation(_ title: String, isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: action)
        }
    }

    /// The same, driven by the thing being deleted rather than a `Bool`, so the dialog can't fire
    /// for one item after the list under it has moved on to another.
    func deleteConfirmation<Item>(
        _ title: String, for item: Binding<Item?>, perform delete: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { value in
            Button("Delete", role: .destructive) { delete(value) }
        }
    }
}
