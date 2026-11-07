import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if let hero = library.featured { HeroBanner(game: hero) }
                else { EmptyCatalog() }
                if !library.continuePlaying.isEmpty { GameRow(title: "Continue Playing", games: library.continuePlaying) }
                if !library.catalog.games.isEmpty { GameRow(title: "All Games", games: library.catalog.games) }
                ForEach(library.catalog.genreRows, id: \.genre) { GameRow(title: $0.genre, games: $0.games) }
            }
            .padding(.bottom, 80)
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
    }
}

private struct EmptyCatalog: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("No games yet").font(.largeTitle.bold()).foregroundStyle(Theme.textPrimary)
            Text("Build a game in TVPort, then install SwitchTV again.").foregroundStyle(Theme.textSecondary)
        }.frame(maxWidth: .infinity, minHeight: 600)
    }
}

/// The big banner for the featured game: its art under the logo-coloured split gradient, Play (when the game is installed) and Details.
struct HeroBanner: View {
    @EnvironmentObject private var library: Library
    let game: CatalogGame

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = Art.image(game.banner) {
                Image(uiImage: image).resizable().scaledToFill().frame(height: 780).clipped()
            } else { Theme.surface.frame(height: 780) }
            Theme.split.opacity(0.9)
            Theme.fadeToPage
            VStack(alignment: .leading, spacing: 18) {
                if library.continuePlaying.first?.id == game.id { Text("CONTINUE PLAYING").font(.caption.weight(.heavy)).tracking(3).foregroundStyle(Theme.accent) }
                Text(game.name).font(.system(size: 76, weight: .heavy)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                if let intro = game.intro ?? game.summary { Text(intro).font(.title3).foregroundStyle(Theme.textSecondary).lineLimit(2).frame(maxWidth: 900, alignment: .leading) }
                HStack(spacing: 24) {
                    if library.canPlay(game) { PlayButton(game: game) }
                    NavigationLink(value: game) { Label("Details", systemImage: "info.circle").padding(.horizontal, 12) }
                }.padding(.top, 8)
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, 50)
        }
        .frame(height: 780)
        .focusSection()
    }
}

struct PlayButton: View {
    @EnvironmentObject private var library: Library
    let game: CatalogGame
    var body: some View {
        Button { library.play(game) } label: { Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 28) }
            .tint(Theme.accent)
    }
}

struct GameRow: View {
    let title: String
    let games: [CatalogGame]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) { ForEach(games) { GameCard(game: $0) } }
                    .padding(.horizontal, Theme.pagePadding).padding(.vertical, 24)   // room for the focus scale
            }
        }.focusSection()
    }
}

struct GameCard: View {
    let game: CatalogGame
    var body: some View {
        NavigationLink(value: game) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Theme.surface
                    if let image = Art.image(game.card) { Image(uiImage: image).resizable().scaledToFill() }
                }
                .frame(width: Theme.cardWidth, height: Theme.cardWidth / Theme.cardAspect).clipped()
                Text(game.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    .frame(width: Theme.cardWidth, alignment: .leading).padding(.bottom, 6)
            }
        }
        .buttonStyle(.card)
    }
}
