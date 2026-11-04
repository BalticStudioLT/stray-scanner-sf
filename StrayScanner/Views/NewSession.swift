//
//  NewSession.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

import SwiftUI

struct NavigationConfigurator: UIViewControllerRepresentable {
    var configure: (UINavigationController) -> Void = { _ in }

    func makeUIViewController(context: UIViewControllerRepresentableContext<NavigationConfigurator>) -> UIViewController {
        UIViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<NavigationConfigurator>) {
        if let nc = uiViewController.navigationController {
            self.configure(nc)
        }
    }
}

struct RecordSessionManager: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    var continueFrom: URL? = nil

    func makeUIViewController(context: Context) -> some UIViewController {
        let viewController = RecordSessionViewController()
        viewController.continueFrom = continueFrom
        viewController.setDismissFunction {
            presentationMode.wrappedValue.dismiss()
            viewController.setDismissFunction(Optional.none)
        }
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}
}

struct NewSessionView : View {
    /// Folder of an earlier scan to continue (same coordinates via its saved world map).
    var continueFrom: URL? = nil

    var body: some View {
        RecordSessionManager(continueFrom: continueFrom)
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)

    }
}

struct NewSessionView_Previews: PreviewProvider {
    static var previews: some View {
        NewSessionView()
    }
}
