import XCTest
@testable import AtlasCore

final class ArticlePageMapTests:XCTestCase {
    static let html="""
    <!DOCTYPE html><html><head><title>Ray Charles</title><style>p{color:red}</style><script>var x="<p>not text</p>";</script></head>
    <body><nav><a href="./Main_Page">Main page</a></nav>
    <h1>Ray Charles</h1>
    <table class="infobox"><tr><th>Label</th><td><a href="./Atlantic_Records" title="Atlantic Records">Atlantic Records</a></td></tr></table>
    <p>Ray Charles Robinson was an <b>American</b> singer &amp; pianist.<br>He signed with <a href="./Atlantic_Records">Atlantic</a> in 1952.</p>
    <!-- a comment with <p>markup</p> -->
    <section><h2 id="Early_life">Early <i>life</i></h2>
    <p>Born in <a href="./Albany%2C_Georgia#History">Albany, Georgia</a>, he moved to Paris&#39;s cousin town.</p>
    <ul><li>First item<ul><li>Nested item</li></ul> tail</li></ul>
    <h3>Blindness</h3><p hidden>Hidden text</p><p style="display: none">Also hidden</p><p>He lost his sight. <img src="x.png" alt="Ray at the piano"></p>
    </section>
    <h2>Legacy</h2><p>See <a href="#cite">[1]</a> and <a href="https://example.com/x">external</a> and <a href='../A/Paris'>the French capital</a>.</p>
    <footer><p>Footer text</p></footer>
    </body></html>
    """

    func testBlocksSectionsAndSkippedContent() {
        let page=ArticlePageMap.make(html:Self.html,document:"Ray_Charles")
        let texts=page.blocks.map(\.text)
        XCTAssertFalse(texts.joined().contains("not text"),"script bodies are skipped")
        XCTAssertFalse(texts.joined().contains("Main page"),"nav is skipped")
        XCTAssertFalse(texts.joined().contains("Footer"),"footer is skipped")
        XCTAssertFalse(texts.joined().contains("hidden"),"hidden elements are skipped")
        XCTAssertFalse(texts.joined().contains("markup"),"comments are skipped")
        XCTAssertTrue(texts.contains("Ray Charles Robinson was an American singer & pianist.\nHe signed with Atlantic in 1952."))
        let early=page.blocks.first {$0.text.hasPrefix("Born in")}
        XCTAssertEqual(early?.section,"Early life")
        XCTAssertEqual(early?.text,"Born in Albany, Georgia, he moved to Paris's cousin town.")
        XCTAssertEqual(page.blocks.first {$0.text == "Early life"}?.section,"Early life","a heading belongs to its own section")
        XCTAssertEqual(page.blocks.first {$0.text.hasPrefix("He lost")}?.section,"Early life › Blindness")
        XCTAssertEqual(page.blocks.first {$0.text.hasPrefix("See")}?.section,"Legacy")
        XCTAssertEqual(page.blocks.first {$0.text.hasPrefix("Ray Charles Robinson")}?.section,"introduction")
        // Nested list items split the outer item, as in the live page map.
        XCTAssertEqual(page.blocks.filter {$0.tag == "li"}.map(\.text),["First item","Nested item"," tail"])
        XCTAssertEqual(page.images.map(\.text),["Ray at the piano"])
        XCTAssertEqual(page.images.first?.section,"Early life › Blindness")
        XCTAssertTrue(page.isTextComplete)
    }

    func testLinksKeepHrefTextAndSection() {
        let page=ArticlePageMap.make(html:Self.html,document:"Ray_Charles")
        XCTAssertEqual(page.links.map(\.text),["Atlantic Records","Atlantic","Albany, Georgia","[1]","external","the French capital"])
        XCTAssertEqual(page.links.first {$0.text == "Albany, Georgia"}?.section,"Early life")
        XCTAssertEqual(ArticleLinks.destinationTitle("./Albany%2C_Georgia#History"),"Albany, Georgia")
        XCTAssertTrue(ArticleLinks.points("../A/Paris",to:"paris"))
        XCTAssertFalse(ArticleLinks.points("#cite",to:"cite"))
        XCTAssertEqual(ArticleLinks.path("./Atlantic_Records",from:"Ray_Charles"),"Atlantic_Records")
        XCTAssertNil(ArticleLinks.path("#cite",from:"Ray_Charles"))
        XCTAssertNil(ArticleLinks.path("https://example.com/x",from:"Ray_Charles"))
    }

    func testTheEngineCountsOnAStaticMap() {
        let page=ArticlePageMap.make(html:Self.html,document:"Ray_Charles")
        var phrase=PageQuery(unit:"phrase");phrase.equals="atlantic"
        XCTAssertEqual(PageQueryEngine.run(phrase,on:page).count,2,"infobox cell and paragraph")
        var links=PageQuery(unit:"link");links.linksTo="Atlantic Records"
        XCTAssertEqual(PageQueryEngine.run(links.normalized(),on:page).count,2,"both links point to Atlantic Records, whatever their text")
        var paris=PageQuery();paris.linksTo="Paris"
        let toParis=PageQueryEngine.run(paris.normalized(),on:page)
        XCTAssertEqual(toParis.count,1)
        XCTAssertEqual(toParis.matches.first?.text,"the French capital")
        XCTAssertEqual(paris.normalized().summary,"links to “Paris”")
    }

    func testTruncationAndEntities() {
        XCTAssertEqual(ArticlePageMap.Parser.decodeEntities("a&nbsp;b &amp; c &#x41;&#66; &unknown; &"),"a\u{00A0}b & c AB &unknown; &")
        let big="<p>"+String(repeating:"word ",count:ArticlePageMap.textLimit/5+10)+"</p>"
        XCTAssertFalse(ArticlePageMap.make(html:big,document:"Big").isTextComplete)
    }
}
