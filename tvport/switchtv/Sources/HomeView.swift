// The home screen, Plex/Netflix style: a hero at the top that always shows the game under focus (backdrop, title, publisher, year, players, genres, description), and the poster rows below it,
// which scroll inside their own area and never move the hero. Select on a poster plays the game; long-press Select (or the Play/Pause button) opens its details.
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: Library
    @FocusState private var focused: String?
    /// The game the hero shows: the last one that had focus.
    @State private var shown: CatalogGame?

    var body: some View {
        let hero = shown ?? library.featured
        ZStack(alignment: .top) {
            Backdrop(game: hero).ignoresSafeArea()
            if let hero {
                VStack(spacing: 0) {
                    HeroInfo(game: hero).frame(height: Theme.heroHeight, alignment: .bottomLeading)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                            if !library.recent.isEmpty { GameRow(id: "recent", title: "Recently Played", games: library.recent, focused: $focused) }
                            GameRow(id: "all", title: "All Games", games: library.catalog.games, focused: $focused)
                            ForEach(library.catalog.genreRows, id: \.genre) { GameRow(id: "genre-\($0.genre)", title: $0.genre, games: $0.games, focused: $focused) }
                        }.padding(.bottom, 80)
                    }
                }
            } else { EmptyCatalog() }
        }
        .onChange(of: focused) { _, key in
            // a poster's focus key is "<row>#<title ID>"
            guard let id = key?.split(separator: "#").last, let game = library.catalog.game(String(id)) else { return }
            withAnimation(.easeInOut(duration: 0.3)) { shown = game }
        }
        .onAppear { library.refresh() }
    }
}

private struct EmptyCatalog: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("No games yet").font(.largeTitle.bold()).foregroundStyle(Theme.textPrimary)
            Text("Build a game in TVPort, then install SwitchTV again.").foregroundStyle(Theme.textSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The game's art over the whole screen, under the logo-coloured split gradient and a fade to the page, so the rows read on the dark lower half. Changing game crossfades.
struct Backdrop: View {
    let game: CatalogGame?
    var body: some View {
        ZStack {
            Theme.background
            if let game {
                ZStack {
                    if let image = Art.image(game.banner) { Image(uiImage: image).resizable().scaledToFill().frame(width: 1920, height: 1080, alignment: .top).clipped() }
                    Theme.split.opacity(0.88)
                    LinearGradient(stops: [.init(color: .clear, location: 0.18), .init(color: Theme.background.opacity(0.9), location: 0.55), .init(color: Theme.background, location: 0.75)], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: 1920, height: 1080)
                .id(game.id).transition(.opacity)
            }
        }
    }
}

/// Title, publisher / year / players, genres and the first lines of the description.
struct HeroInfo: View {
    let game: CatalogGame
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.name).font(.system(size: 64, weight: .heavy)).foregroundStyle(Theme.textPrimary).lineLimit(2).minimumScaleFactor(0.7)
            if !game.metaText.isEmpty { Text(game.metaText).font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary) }
            if !game.genres.isEmpty { Text(game.genres.joined(separator: "  /  ")).font(.callout.weight(.bold)).foregroundStyle(Theme.accent) }
            if let text = game.blurb { Text(text).font(.body).foregroundStyle(Theme.textSecondary).lineLimit(3).frame(maxWidth: 1000, alignment: .leading) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding).padding(.bottom, 28)
        .id(game.id).transition(.opacity)
    }
}

struct GameRow: View {
    let id: String
    let title: String
    let games: [CatalogGame]
    var focused: FocusState<String?>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) { ForEach(games) { GameCard(game: $0, focusKey: "\(id)#\($0.titleID)", focused: focused) } }
                    .padding(.horizontal, Theme.pagePadding).padding(.vertical, 24)   // room for the focus scale
            }
        }.focusSection()
    }
}

/// Select plays; long-press Select shows a menu (Play, Details); Play/Pause opens the details.
struct GameCard: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var router: Router
    let game: CatalogGame
    let focusKey: String
    var focused: FocusState<String?>.Binding

    var body: some View {
        Button { library.select(game) } label: {
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
        .focused(focused, equals: focusKey)
        .onPlayPauseCommand { router.show(game) }
        .contextMenu {
            Button("Play") { library.select(game) }
            Button("Details") { router.show(game) }
        }
    }
}
