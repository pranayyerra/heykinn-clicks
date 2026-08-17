import XCTest
@testable import HeykinnClicks

/// An album's own metadata, which was captured from the first pass and shown
/// nowhere until there was somewhere to show it.
final class AlbumDetailTests: XCTestCase {

    /// The shape a real album `metadata.json` arrives in. Taken from a real
    /// payload and then stripped: the structure, the key names and the empty
    /// `description` are what matter here, so the titles, places and
    /// coordinates are stand-ins.
    private let real = """
    {"title": "Wednesday night in Northgate",
     "description": "", "access": "protected",
     "date": {"timestamp": "1436992187", "formatted": "Jul 15, 2015, 8:29:47 PM UTC"},
     "enrichments": [
       {"locationEnrichment": {"location": [
         {"name": "Market Ward", "description": "Northgate",
          "latitudeE7": 100000000, "longitudeE7": 200000000}]}},
       {"locationEnrichment": {"location": [
         {"name": "Elm Park", "description": "Northgate",
          "latitudeE7": 100100000, "longitudeE7": 200100000}]}}]}
    """

    /// Places are the whole point of reading this. Google recorded "Elm Park"
    /// against an album in 2015 and no photo in it carries that anywhere — the
    /// payload is the only surviving record, and it was already captured.
    func testReadsPlacesFromNestedEnrichments() {
        let detail = MetadataProjection.albumDetail(in: real)
        XCTAssertEqual(detail?.title, "Wednesday night in Northgate")
        XCTAssertEqual(detail?.places.map(\.name), ["Market Ward", "Elm Park"])
        XCTAssertEqual(detail?.places.first?.locality, "Northgate")
    }

    func testReadsTheAlbumsOwnDate() {
        XCTAssertEqual(
            MetadataProjection.albumDetail(in: real)?.date,
            Date(timeIntervalSince1970: 1436992187)
        )
    }

    /// Every one of the 29 albums on a real archive has `"description": ""`.
    /// An empty string must not become an empty line under the title, so it is
    /// dropped here rather than checked for at every place that draws it.
    func testEmptyDescriptionIsNoDescription() {
        XCTAssertNil(MetadataProjection.albumDetail(in: real)?.description)
    }

    /// Google's `enrichments` is a list of single-key objects, and
    /// `locationEnrichment` is only the kind that exists today. An unfamiliar
    /// kind must be stepped over, not crashed on and not guessed at — the
    /// payload keeps it for a projection that understands it.
    func testUnknownEnrichmentKindsAreSkippedNotGuessedAt() {
        let payload = """
        {"title": "Trip", "enrichments": [
          {"textEnrichment": {"text": "The drive up"}},
          {"locationEnrichment": {"location": [{"name": "Highvale"}]}}]}
        """
        let detail = MetadataProjection.albumDetail(in: payload)
        XCTAssertEqual(detail?.places.map(\.name), ["Highvale"])
        XCTAssertNil(detail?.places.first?.locality)
    }

    /// An album with nothing but a title is still an album. Most of them are.
    func testTitleAloneIsEnough() {
        let detail = MetadataProjection.albumDetail(in: #"{"title": "Spring 2016"}"#)
        XCTAssertEqual(detail?.title, "Spring 2016")
        XCTAssertNil(detail?.date)
        XCTAssertTrue(detail?.places.isEmpty == true)
    }

    /// A payload with no title is not an album, however else it is shaped —
    /// the title is what the tag is keyed on, so there is nothing to attach.
    func testNoTitleIsNotAnAlbum() {
        XCTAssertNil(MetadataProjection.albumDetail(in: #"{"date": {"timestamp": "1"}}"#))
    }
}

/// The parts of an album's metadata that only showed up once it was read back
/// off a real archive.
extension AlbumDetailTests {

    /// `mapEnrichment` is a trip, not two more pins. A real album recorded
    /// Northgate → Seaside, and flattening it into the place list would say
    /// the weekend was spent in both.
    func testMapEnrichmentIsAJourneyNotTwoPlaces() {
        let payload = """
        {"title": "Weekend in Seaside", "enrichments": [
          {"mapEnrichment": {
            "origin": [{"name": "Northgate", "description": "Northshire"}],
            "destination": [{"name": "Seaside", "description": "Southshore"}]}}]}
        """
        let detail = MetadataProjection.albumDetail(in: payload)
        XCTAssertTrue(detail?.places.isEmpty == true)
        XCTAssertEqual(detail?.journeys.count, 1)
        XCTAssertEqual(detail?.journeys.first?.from.name, "Northgate")
        XCTAssertEqual(detail?.journeys.first?.to.locality, "Southshore")
    }

    /// Google repeats a place when the album returns to it. "Weekend in Highvale
    /// and Fernwood" listed ten locations of which two pairs were identical,
    /// which reads as a stutter rather than as a longer trip.
    func testRepeatedPlacesAreListedOnce() {
        let payload = """
        {"title": "Weekend in Highvale", "enrichments": [
          {"locationEnrichment": {"location": [
            {"name": "Fernwood", "description": "Northshire"},
            {"name": "Highvale", "description": "Northshire"},
            {"name": "Fernwood", "description": "Northshire"}]}}]}
        """
        XCTAssertEqual(
            MetadataProjection.albumDetail(in: payload)?.places.map(\.name),
            ["Fernwood", "Highvale"]
        )
    }

    /// Two places sharing a name in different states are two places. Deduping
    /// on the name alone would drop one of them.
    func testSameNameInDifferentPlacesIsTwoPlaces() {
        let payload = """
        {"title": "Trip", "enrichments": [
          {"locationEnrichment": {"location": [
            {"name": "Springfield", "description": "Illinois"},
            {"name": "Springfield", "description": "Missouri"}]}}]}
        """
        XCTAssertEqual(MetadataProjection.albumDetail(in: payload)?.places.count, 2)
    }

    /// A half-written map — an origin with no destination — is not a journey,
    /// and must not become one with a blank end.
    func testIncompleteMapIsNoJourney() {
        let payload = """
        {"title": "Trip", "enrichments": [
          {"mapEnrichment": {"origin": [{"name": "Northgate"}]}}]}
        """
        XCTAssertTrue(MetadataProjection.albumDetail(in: payload)?.journeys.isEmpty == true)
    }
}

/// How a provider's own dates are printed.
extension AlbumDetailTests {

    /// An album titled "Wednesday night in Northgate" carries the UTC instant
    /// `1436992187` — Wednesday 15 July 2015, 8:29 PM UTC, which Google itself
    /// printed as "Jul 15". Rendered anywhere east of UTC+3:31 that instant is
    /// already the 16th — 2 AM at UTC+5:30 — so the header called a Wednesday
    /// album Thursday, and would have said something different again on a
    /// device in another timezone.
    ///
    /// A provider's day is shown as the provider's day.
    func testProviderDaysAreShownInTheProvidersOwnTimezone() {
        let instant = Date(timeIntervalSince1970: 1436992187)
        // Any zone far enough east to roll the date over; the identifier is
        // incidental, the offset is the point.
        let eastOfUTC = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!

        let local = DateFormatter()
        local.dateStyle = .long
        local.timeStyle = .none
        local.timeZone = eastOfUTC
        XCTAssertTrue(
            local.string(from: instant).contains("16"),
            "the premise: rendered locally this instant lands on the 16th"
        )

        XCTAssertTrue(
            Formatters.providerDateOnly.string(from: instant).contains("15"),
            "so the header must print the 15th, the day Google itself recorded"
        )
    }
}
