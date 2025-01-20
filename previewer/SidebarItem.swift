//
//  SidebarItem.swift
//  previewer
//
//  Created by Jonathan Harris on 18/01/2025.
//

import Cocoa

class SidebarItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("sidebar-item")

    override func loadView() {
        super.loadView()
        imageView!.wantsLayer = true
    }

    override var isSelected: Bool {
        didSet {
            if !isViewLoaded {
                return
            }
            let showAsHighlighted =
                (highlightState == .forSelection)
                || (isSelected && highlightState != .forDeselection)
                || (highlightState == .asDropTarget)

            view.layer?.backgroundColor = showAsHighlighted ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : nil
        }
    }

}
