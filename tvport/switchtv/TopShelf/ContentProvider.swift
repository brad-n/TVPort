// The Top Shelf of SwitchTV: while SwitchTV sits in the top row of the Apple TV home screen it shows "Recently Played" and "All Games" (Shared/Shelf.swift decides what), and Select on one opens that game.
import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let store = SharedStore()
        let sections = Shelf.sections(catalog: Catalog.load(), lastPlayed: store?.lastPlayed() ?? [:], launchable: store?.launchable(), imageFolder: Catalog.folder)
        guard !sections.isEmpty else { return completionHandler(nil) }   // nothing to show: the static Top Shelf image stays
        completionHandler(TVTopShelfSectionedContent(sections: sections.map { section in
            let items: [TVTopShelfSectionedItem] = section.items.map { entry in
                let item = TVTopShelfSectionedItem(identifier: entry.identifier)
                item.title = entry.name
                item.imageShape = .hdtv
                if let image = entry.image { item.setImageURL(image, for: [.screenScale1x, .screenScale2x]) }
                item.playAction = TVTopShelfAction(url: entry.action)
                item.displayAction = TVTopShelfAction(url: entry.action)
                return item
            }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            return collection
        }))
    }
}
