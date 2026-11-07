import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var library: Library
    let game: CatalogGame

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()
            if let image = Art.image(game.banner) {
                Image(uiImage: image).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: 900, alignment: .top).clipped().ignoresSafeArea()
            }
            Theme.split.ignoresSafeArea().opacity(0.92)
            Theme.fadeToPage.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Spacer().frame(height: 120)
                    Text(game.name).font(.system(size: 70, weight: .heavy)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    metaLine
                    if !game.genres.isEmpty {
                        HStack(spacing: 12) { ForEach(game.genres, id: \.self) { Text($0).font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 6).background(Theme.accent.opacity(0.85), in: Capsule()) } }
                    }
                    if let text = game.summary ?? game.intro {
                        Text(text).font(.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: 1000, alignment: .leading).lineLimit(8)
                    }
                    playArea
                    if !game.screenshots.isEmpty { Screenshots(urls: game.screenshots) }
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, 60)
            }
        }
        .onAppear { library.refreshInstalled() }
    }

    private var metaLine: some View {
        let parts = [game.publisher, game.releaseText, game.playersText].compactMap { $0 }
        return Text(parts.joined(separator: "  \u{2022}  ")).font(.title3).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder private var playArea: some View {
        if library.canPlay(game) { PlayButton(game: game) }
        else {
            Text("Rebuild this game in TVPort to play it from SwitchTV")
                .font(.headline).foregroundStyle(Theme.textPrimary).padding(.horizontal, 28).padding(.vertical, 16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: 2))
                .focusable()
        }
    }
}

/// Screenshots come from the web: an offline Apple TV shows plain placeholders instead of failing.
struct Screenshots: View {
    let urls: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screenshots").font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(urls, id: \.self) { link in
                        Button {} label: {
                            AsyncImage(url: URL(string: link)) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFill()
                                default: ZStack { Theme.surface; Image(systemName: "photo").font(.largeTitle).foregroundStyle(Theme.textTertiary) }
                                }
                            }
                            .frame(width: 520, height: 292).clipped()
                        }.buttonStyle(.card)
                    }
                }.padding(.vertical, 24)
            }
        }.focusSection()
    }
}
