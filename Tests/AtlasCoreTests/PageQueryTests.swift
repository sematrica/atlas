import XCTest
@testable import AtlasCore

final class PageQueryTests:XCTestCase {
    private let rect=TerrainRect(x:0,y:0,width:700,height:100)

    private func page(_ blocks:[(id:String,text:String,section:String,tag:String)],links:[CrawlerPageItem]=[],images:[CrawlerPageItem]=[])->CrawlerPageMap {
        CrawlerPageMap(document:"test",revision:1,textRevision:1,viewport:rect,documentWidth:800,documentHeight:1200,
                       blocks:blocks.map {CrawlerPageItem(id:$0.id,text:$0.text,rect:rect,section:$0.section,tag:$0.tag)},links:links,images:images)
    }
    private func run(_ query:PageQuery,_ page:CrawlerPageMap)->PageQueryResult {PageQueryEngine.run(query,on:page)}
    private func query(_ configure:(inout PageQuery)->Void)->PageQuery {var q=PageQuery();configure(&q);return q}

    private lazy var article=page([
        ("title","Ray Charles","introduction","h1"),
        ("intro","A yellow bird sat on a narrow branch near a new house. Anchor after anchor, the bird was a famous singer!","introduction","p"),
        ("career-heading","Career","Career","h2"),
        ("career","Ray Charles recorded in Paris. He played 3 pianos in 1959. Ray Charles sang.","Career","p"),
        ("legacy-heading","Legacy","Legacy","h2"),
        ("legacy","The ANCHOR stayed. Another tiny insect watches.","Legacy","p")
    ],links:[
        CrawlerPageItem(id:"l1",text:"Atlantic Records",rect:rect,href:"Atlantic_Records",section:"Career"),
        CrawlerPageItem(id:"l2",text:"piano",rect:rect,href:"Piano",section:"Career"),
        CrawlerPageItem(id:"l3",text:"[1]",rect:rect,href:"#cite-1",section:"Legacy")
    ],images:[CrawlerPageItem(id:"i1",text:"Ray at the piano",rect:rect,section:"introduction")])

    func testWordsStartingAndEndingWithLetters() {
        let result=run(query {$0.unit="word";$0.startsWith="a";$0.endsWith="r"},article)
        XCTAssertEqual(result.matches.map(\.text),["Anchor","after","anchor","ANCHOR","Another"])
        XCTAssertEqual(result.count,5)
    }

    func testAdjectivesEndingWithW() {
        let result=run(query {$0.unit="adjectives";$0.endsWith="w"},article)
        XCTAssertEqual(result.matches.map(\.text),["yellow","narrow","new"])
    }

    func testPeriodsCapitalLettersAndLinks() {
        XCTAssertEqual(run(query {$0.unit="periods"},article).count,6)
        XCTAssertEqual(run(query {$0.unit="character";$0.equals="."},article).count,6)
        let capitals=run(query {$0.unit="capital letters"},article)
        XCTAssertEqual(capitals.count,20)
        XCTAssertTrue(capitals.matches.allSatisfy {$0.text.count == 1 && $0.text.first!.isUppercase})
        XCTAssertEqual(run(query {$0.unit="hyperlinks"},article).count,3)
        XCTAssertEqual(run(query {$0.unit="link";$0.section="Career"},article).count,2)
        XCTAssertEqual(run(query {$0.unit="images"},article).count,1)
    }

    func testRangesPointAtTheRealSourceText() throws {
        let text="🕷️ Hi. The extraordinary creature walks confidently."
        let p=page([("a",text,"introduction","p")])
        let word=try XCTUnwrap(run(query {$0.unit="word";$0.order="longest"},p).matches.first?.range)
        XCTAssertEqual(word.text,"extraordinary")
        XCTAssertEqual((text as NSString).substring(with:NSRange(location:word.start,length:word.end-word.start)),"extraordinary")
        let letters=run(query {$0.unit="letter";$0.equals="e"},p).matches
        for match in letters {
            let range=try XCTUnwrap(match.range)
            XCTAssertEqual((text as NSString).substring(with:NSRange(location:range.start,length:range.end-range.start)).lowercased(),"e")
        }
    }

    func testRankingUsesDistinctSpellingsAndAlphabeticalTies() {
        let p=page([("a","🕷️ astronomy astronomy butterfly mountains butterfly field","introduction","p")])
        XCTAssertEqual(run(query {$0.order="longest";$0.rank=1},p).matches.first?.text,"astronomy")
        XCTAssertEqual(run(query {$0.order="longest";$0.rank=2},p).matches.first?.text,"butterfly")
        XCTAssertEqual(run(query {$0.order="longest";$0.rank=2;$0.distinct=false},p).matches.first?.text,"astronomy")
        XCTAssertTrue(run(query {$0.order="longest";$0.rank=100},p).matches.isEmpty)
        XCTAssertEqual(run(query {$0.order="longest";$0.limit=2},p).matches.map(\.text),["astronomy","butterfly"])
    }

    func testReadingOrderSelectionsAndSections() {
        XCTAssertEqual(run(query {$0.order="first"},article).matches.map(\.text),["Ray"])
        XCTAssertEqual(run(query {$0.order="last"},article).matches.map(\.text),["watches"])
        XCTAssertEqual(run(query {$0.order="first";$0.section="Legacy"},article).matches.map(\.text),["Legacy"])
        XCTAssertEqual(run(query {$0.order="first";$0.rank=2},article).matches.map(\.text),["Charles"])
        let missing=run(query {$0.section="Discography"},article)
        XCTAssertEqual(missing.unknownSection,"Discography")
        XCTAssertTrue(missing.sections.contains("Career"))
        let intro=run(query {$0.unit="word";$0.section="the intro"},article)
        XCTAssertTrue(intro.matches.allSatisfy {$0.range?.id == "title" || $0.range?.id == "intro"})
        let outside=run(query {$0.unit="word";$0.excludeSections=["Career","Legacy"]},article)
        XCTAssertFalse(outside.matches.contains {$0.range?.id == "career"})
    }

    func testFrequencyAndDistinctCounts() {
        let frequent=run(query {$0.order="most common";$0.exclude=["a"]},article)
        XCTAssertEqual(frequent.frequencies.first?.text.lowercased(),"ray")
        XCTAssertEqual(frequent.frequencies.first?.count,3)
        XCTAssertEqual(frequent.matches.count,3,"Every occurrence of the most common word is a match")
        let all=run(query {$0.unit="word"},article).count
        let unique=run(query {$0.unit="word";$0.distinct=true},article).count
        XCTAssertLessThan(unique,all)
    }

    func testCaseLengthAndNegatedConditions() {
        XCTAssertEqual(run(query {$0.unit="word";$0.letterCase="uppercase"},article).matches.map(\.text),["ANCHOR"])
        let capitalized=run(query {$0.unit="word";$0.letterCase="capitalized"},article).matches.map(\.text)
        XCTAssertTrue(capitalized.contains("Paris"));XCTAssertFalse(capitalized.contains("bird"))
        XCTAssertEqual(run(query {$0.unit="word";$0.length=13},page([("a","An extraordinary day","introduction","p")])).matches.map(\.text),["extraordinary"])
        let short=run(query {$0.unit="word";$0.maxLength=2;$0.section="Career"},article).matches.map(\.text)
        XCTAssertEqual(short,["in","He","in"])
        let notA=run(query {$0.unit="word";$0.startsWith="a";$0.notEndsWith="r"},article).matches.map {$0.text.lowercased()}
        XCTAssertEqual(Set(notA),["a"],"Every a-word ending in r is removed")
        let alternatives=run(query {$0.unit="word";$0.startsWith="p|h";$0.section="Career"},article).matches.map(\.text)
        XCTAssertEqual(alternatives,["Paris","He","played","pianos"])
    }

    func testCharacterClassesNumbersSentencesAndPhrases() {
        XCTAssertEqual(run(query {$0.unit="digits"},article).count,5)
        XCTAssertEqual(run(query {$0.unit="numbers"},article).matches.map(\.text),["3","1959"])
        XCTAssertEqual(run(query {$0.unit="vowels";$0.section="Legacy"},article).count,15)
        XCTAssertEqual(run(query {$0.unit="sentence";$0.section="Career"},article).count,3)
        XCTAssertEqual(run(query {$0.unit="phrase";$0.equals="ray charles"},article).count,3)
        XCTAssertEqual(run(query {$0.unit="word";$0.equals="Ray Charles"},article).count,3,"A multi-word spelling becomes a phrase search")
        XCTAssertEqual(run(query {$0.unit="headings"},article).matches.map(\.text),["Ray Charles","Career","Legacy"])
        XCTAssertEqual(run(query {$0.unit="paragraphs"},article).count,3)
    }

    func testNormalizationAndValidation() {
        XCTAssertEqual(query {$0.unit="Capital Letters"}.normalized().letterCase,"uppercase")
        XCTAssertEqual(query {$0.unit="nouns"}.normalized().partOfSpeech,"noun")
        XCTAssertEqual(query {$0.unit="question marks"}.normalized().equals,"?")
        XCTAssertEqual(query {$0.unit="people"}.normalized().entity,"person")
        XCTAssertEqual(query {$0.order="longest"}.normalized().limit,1)
        XCTAssertEqual(query {$0.rank=3}.normalized().order,"first")
        XCTAssertEqual(query {$0.startsWith="'a'"}.normalized().startsWith,"a")
        XCTAssertEqual(query {$0.section="Early life section"}.normalized().section,"Early life")
        XCTAssertTrue(query {$0.unit="adjectives";$0.endsWith="w"}.normalized().problems.isEmpty)
        XCTAssertFalse(query {$0.unit="paragraphs";$0.partOfSpeech="noun"}.normalized().problems.isEmpty)
        XCTAssertFalse(query {$0.unit="spaceships"}.normalized().problems.isEmpty)
        XCTAssertFalse(query {$0.unit="word";$0.characterClass="digit"}.normalized().problems.isEmpty)
    }

    func testLenientDecoding() throws {
        let json=#"{"unit":"words","startsWith":"","minLength":"4","distinct":"yes","exclude":"the, of","rank":2.0}"#
        let q=try JSONDecoder().decode(PageQuery.self,from:Data(json.utf8)).normalized()
        XCTAssertEqual(q.unit,"word");XCTAssertNil(q.startsWith);XCTAssertEqual(q.minLength,4)
        XCTAssertEqual(q.distinct,true);XCTAssertEqual(q.exclude,["the","of"]);XCTAssertEqual(q.rank,2)
    }

    func testSummaries() {
        XCTAssertEqual(query {$0.unit="adjective";$0.endsWith="w"}.summary,"adjectives ending with “w”")
        XCTAssertEqual(query {$0.unit="capital letters"}.summary,"capital letters")
        XCTAssertEqual(query {$0.unit="periods"}.summary,"periods (.)")
        XCTAssertEqual(query {$0.unit="word";$0.startsWith="a";$0.endsWith="r"}.summary,"words starting with “a” and ending with “r”")
        XCTAssertEqual(query {$0.order="longest";$0.rank=2}.summary,"the 2nd longest word")
        XCTAssertEqual(query {$0.unit="verbs";$0.section="introduction"}.summary,"verbs in the introduction")
        XCTAssertEqual(query {$0.order="frequent";$0.limit=5}.summary,"the 5 most common words")
    }

    func testPlacesAndLinks() {
        XCTAssertEqual(PageQueryEngine.locate("the Legacy section",on:article)?.text,"Legacy")
        XCTAssertEqual(PageQueryEngine.locate("career",on:article)?.range?.id,"career-heading")
        XCTAssertEqual(PageQueryEngine.locate("top",on:article)?.range?.id,"title")
        XCTAssertEqual(PageQueryEngine.findLink("atlantic records",on:article)?.id,"l1")
        XCTAssertEqual(PageQueryEngine.findLink("Piano",on:article)?.id,"l2")
        XCTAssertEqual(PageQueryEngine.locate("tiny insect",on:article)?.range?.id,"legacy")
    }
}
