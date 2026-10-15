import XCTest
@testable import AtlasCore

final class CompanionParserTests:XCTestCase {
    private func step(_ request:String,file:StaticString=#filePath,line:UInt=#line)->CompanionStep? {
        let plan=CompanionLocalParser.parse(request)
        XCTAssertEqual(plan?.steps.count,1,"“\(request)” should be understood locally",file:file,line:line)
        XCTAssertEqual(plan?.local,true,file:file,line:line)
        return plan?.steps.first
    }

    func testTheUsersOwnExamples() {
        let a=step("find me all the words that start with a and ends with r")
        XCTAssertEqual(a?.action,"highlight");XCTAssertEqual(a?.query?.unit,"word")
        XCTAssertEqual(a?.query?.startsWith,"a");XCTAssertEqual(a?.query?.endsWith,"r")

        let b=step("find all adjective that ends with w and highlight it with green")
        XCTAssertEqual(b?.action,"highlight");XCTAssertEqual(b?.query?.partOfSpeech,"adjective")
        XCTAssertEqual(b?.query?.endsWith,"w");XCTAssertEqual(HighlightStyle.parse(b?.color)?.colors,["#008000"])

        let c=step("How many dots are in this article?")
        XCTAssertEqual(c?.action,"count");XCTAssertEqual(c?.query?.unit,"character");XCTAssertEqual(c?.query?.equals,".")

        let d=step("how many links in this article")
        XCTAssertEqual(d?.action,"count");XCTAssertEqual(d?.query?.unit,"link")

        let e=step("how many capital letters in this article")
        XCTAssertEqual(e?.action,"count");XCTAssertEqual(e?.query?.unit,"letter");XCTAssertEqual(e?.query?.letterCase,"uppercase")

        let f=step("highlight the verbs half green half yellow")
        XCTAssertEqual(f?.query?.partOfSpeech,"verb");XCTAssertEqual(HighlightStyle.parse(f?.color)?.mode,.split)

        // Addressing the companion by name doesn't stop local understanding.
        XCTAssertEqual(step("hey Sematrica, how many links in this article")?.query?.unit,"link")
    }

    func testCountingVariants() {
        XCTAssertEqual(step("count the commas")?.query?.equals,",")
        XCTAssertEqual(step("How many periods does this page have?")?.query?.equals,".")
        XCTAssertEqual(step("what's the number of question marks")?.query?.equals,"?")
        let sentences=step("how many sentences are in the Career section")
        XCTAssertEqual(sentences?.query?.unit,"sentence");XCTAssertEqual(sentences?.query?.section,"career")
        let long=step("how many words have more than 10 letters")
        XCTAssertEqual(long?.query?.minLength,11)
        XCTAssertEqual(step("how many 5-letter words are there")?.query?.length,5)
        XCTAssertEqual(step("how many unique words")?.query?.distinct,true)
        XCTAssertEqual(step("count all the vowels in the introduction")?.query?.section,"introduction")
        XCTAssertEqual(step("how many sentences have more than 30 words")?.query?.minWords,31)
        XCTAssertEqual(step("how many images")?.query?.unit,"image")
        XCTAssertEqual(step("how many sections are there")?.query?.unit,"heading")
    }

    func testHighlightingVariants() {
        let blue=step("Please highlight all nouns in light blue")
        XCTAssertEqual(blue?.action,"highlight");XCTAssertEqual(blue?.query?.partOfSpeech,"noun")
        XCTAssertEqual(HighlightStyle.parse(blue?.color)?.colors,["#add8e6"])
        let negated=step("highlight words that don't start with s")
        XCTAssertEqual(negated?.query?.notStartsWith,"s")
        let either=step("mark words starting with a or e in red")
        XCTAssertEqual(either?.query?.startsWith,"a|e")
        let counted=step("count the adjectives and highlight them in alternating red and blue")
        XCTAssertEqual(counted?.action,"highlight");XCTAssertEqual(HighlightStyle.parse(counted?.color)?.mode,.alternate)
        let quoted=step("find words containing \"th\"")
        XCTAssertEqual(quoted?.query?.contains,"th")
        let letter=step("highlight words with the letter z")
        XCTAssertEqual(letter?.query?.contains,"z")
        let excluded=step("highlight the verbs outside the References section")
        XCTAssertEqual(excluded?.query?.excludeSections,["references"])
        XCTAssertEqual(step("show me all the people")?.query?.entity,"person")
        XCTAssertEqual(step("where are the adjectives")?.action,"highlight")
    }

    func testSelectionsAndMovement() {
        let second=step("go to the second longest word")
        XCTAssertEqual(second?.action,"goto");XCTAssertEqual(second?.query?.order,"longest");XCTAssertEqual(second?.query?.rank,2)
        let longest=step("what is the longest word?")
        XCTAssertEqual(longest?.action,"list");XCTAssertEqual(longest?.query?.order,"longest")
        let five=step("highlight the 5 longest words in red")
        XCTAssertEqual(five?.query?.limit,5);XCTAssertEqual(five?.action,"highlight")
        XCTAssertEqual(step("take me to the first sentence")?.query?.order,"first")
        XCTAssertEqual(step("what's the most common word")?.query?.order,"frequent")
        let first3=step("list the first 3 sentences")
        XCTAssertEqual(first3?.query?.order,"first");XCTAssertEqual(first3?.query?.limit,3)
        let place=step("take me to the Early life section")
        XCTAssertEqual(place?.action,"go");XCTAssertEqual(place?.place,"early life")
        XCTAssertEqual(step("go to the top")?.place,"top")
    }

    func testControlCommands() {
        XCTAssertEqual(step("stop")?.action,"stop")
        XCTAssertEqual(step("Faster please")?.speed,"faster")
        XCTAssertEqual(step("slow down")?.speed,"slower")
        XCTAssertEqual(step("clear all highlights")?.action,"clear")
        XCTAssertEqual(step("stay in this article")?.rule,"stay")
        XCTAssertEqual(step("go back")?.action,"back")
        XCTAssertEqual(step("wander around")?.action,"wander")
    }

    func testAnythingUnclearGoesToTheModel() {
        for request in ["What do you think of this article?","highlight words related to music","open the article about Paris",
                        "how many words except the","find words of French origin","Hello!","highlight the green ones",
                        "how many dots in this letter","go to Paris","find the sentence about his childhood",
                        "highlight verbs and nouns","count words in history"] {
            XCTAssertNil(CompanionLocalParser.parse(request),"“\(request)” must go to the model")
        }
    }
}

final class HighlightStyleTests:XCTestCase {
    func testColorPhrases() throws {
        XCTAssertEqual(HighlightStyle.parse("green")?.colors,["#008000"])
        XCTAssertEqual(HighlightStyle.parse("in dark green")?.colors,["#006400"])
        XCTAssertEqual(HighlightStyle.parse("#f80")?.colors,["#ff8800"])
        let split=try XCTUnwrap(HighlightStyle.parse("half green half yellow"))
        XCTAssertEqual(split.mode,.split);XCTAssertEqual(split.colors.count,2)
        XCTAssertEqual(HighlightStyle.parse("half of them green and half yellow")?.mode,.groups)
        XCTAssertEqual(HighlightStyle.parse("alternate red and blue")?.mode,.alternate)
        XCTAssertEqual(HighlightStyle.parse("a gradient from blue to purple")?.mode,.gradient)
        XCTAssertEqual(HighlightStyle.parse("rainbow")?.mode,.gradient)
        XCTAssertEqual(HighlightStyle.parse("underline them in red")?.underline,true)
        XCTAssertEqual(HighlightStyle.parse("make the text red")?.textOnly,true)
        XCTAssertNil(HighlightStyle.parse("nicely"))
        XCTAssertTrue(HighlightStyle.recognizes("in half green and half yellow"))
        XCTAssertFalse(HighlightStyle.recognizes("in the history section"))
        XCTAssertEqual(HighlightStyle.ink(for:"#0000ff"),"#ffffff")
        XCTAssertEqual(HighlightStyle.ink(for:"#ffff00"),"#111111")
    }

    func testPaintingSplitsOnCharacterBoundaries() {
        let rect=TerrainRect(x:0,y:0,width:10,height:10)
        let matches=[PageMatch(range:.init(id:"a",start:4,end:10,text:"yellow"),elementID:nil,text:"yellow",rect:rect,order:0),
                     PageMatch(range:.init(id:"a",start:20,end:23,text:"new"),elementID:nil,text:"new",rect:rect,order:1),
                     PageMatch(range:nil,elementID:"link",text:"Paris",rect:rect,order:2)]
        let split=HighlightStyle.parse("half green half yellow")!.paints(for:matches)
        XCTAssertEqual(split.filter {$0.id == "a"}.map {[$0.start!,$0.end!,$0.color]},[[4,7,0],[7,10,1],[20,21,0],[21,23,1]])
        XCTAssertEqual(split.last,HighlightPaint(id:"link",start:nil,end:nil,color:0))
        let alternate=HighlightStyle.parse("alternate red and blue")!.paints(for:matches)
        XCTAssertEqual(alternate.map(\.color),[0,1,0])
        let groups=HighlightStyle.parse("half of them red and the rest blue")!.paints(for:matches)
        XCTAssertEqual(groups.map(\.color),[0,0,1])
        let emoji=HighlightStyle.pieces(.init(id:"a",start:0,end:5,text:"🕷️ab"),parts:2)
        XCTAssertEqual(emoji.map {$0.end-$0.start}.reduce(0,+),5)
        let gradient=HighlightStyle.parse("gradient from red to blue")!
        XCTAssertEqual(gradient.palette.count,12);XCTAssertEqual(gradient.palette.first,"#ff0000");XCTAssertEqual(gradient.palette.last,"#0000ff")
    }
}

final class CompanionPlanTests:XCTestCase {
    func testDecodingNormalizesWhatSmallModelsProduce() throws {
        let raw="""
        Sure! ```json
        {"steps":[{"action":"find","query":{"unit":"adjectives","endsWith":"w"},"color":"green"},{"action":"how many","query":{"unit":"Links"}},{"action":"answer"}],"reply":"On it."}
        ```
        """
        let plan=try XCTUnwrap(CompanionPlan.decode(raw)).normalized()
        XCTAssertEqual(plan.steps.map(\.action),["highlight","count"])
        XCTAssertEqual(plan.steps[0].query?.partOfSpeech,"adjective")
        XCTAssertEqual(plan.steps[1].query?.unit,"link")
        XCTAssertTrue(plan.problems.isEmpty)
        XCTAssertEqual(plan.reply,"On it.")
    }

    func testSingleStepObjectAndMissingFields() throws {
        let plan=try XCTUnwrap(CompanionPlan.decode(#"{"steps":{"action":"faster"},"reply":""}"#)).normalized()
        XCTAssertEqual(plan.steps.first?.action,"speed");XCTAssertEqual(plan.steps.first?.speed,"faster")
        XCTAssertNil(plan.reply)
        let invalid=try XCTUnwrap(CompanionPlan.decode(#"{"steps":[{"action":"executeJavaScript"},{"action":"go"}],"reply":"x"}"#)).normalized()
        XCTAssertEqual(invalid.problems.count,2)
    }

    func testSchemaIsValidOrderedJSON() throws {
        let json=CompanionPlan.schemaJSON
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        XCTAssertEqual(object["type"] as? String,"object")
        // The model must choose an action before its details, and steps before the reply.
        XCTAssertLessThan(json.range(of:"\"steps\"")!.lowerBound,json.range(of:"\"reply\"")!.lowerBound)
        XCTAssertLessThan(json.range(of:"\"action\"")!.lowerBound,json.range(of:"\"query\"")!.lowerBound)
        XCTAssertLessThan(json.range(of:"\"unit\"")!.lowerBound,json.range(of:"\"startsWith\"")!.lowerBound)
    }
}

final class LibraryParserTests:XCTestCase {
    private func library(_ request:String,file:StaticString=#filePath,line:UInt=#line)->CompanionStep? {
        let plan=CompanionLocalParser.parse(request)
        XCTAssertEqual(plan?.steps.first?.action,"library","“\(request)” should be a library question",file:file,line:line)
        XCTAssertEqual(plan?.local,true,file:file,line:line)
        return plan?.steps.first
    }

    func testTheUsersExamples() {
        let a=library("how many articles mention Atlantic Records")
        XCTAssertEqual(a?.measure,"articles");XCTAssertEqual(a?.scope,"library")
        XCTAssertEqual(a?.query?.unit,"phrase");XCTAssertEqual(a?.query?.equals,"Atlantic Records","the user's own capitalization")

        let b=library("Which articles link to Paris?")
        XCTAssertEqual(b?.measure,"list");XCTAssertEqual(b?.query?.unit,"link");XCTAssertEqual(b?.query?.linksTo,"Paris")

        let c=library("count jazz in the articles linked in the Discography section")
        XCTAssertEqual(c?.measure,"total");XCTAssertEqual(c?.scope,"linked");XCTAssertEqual(c?.place,"Discography")
        XCTAssertEqual(c?.query?.unit,"word","one word is matched as a whole word");XCTAssertEqual(c?.query?.equals,"jazz")
    }

    func testOtherPhrasings() {
        XCTAssertEqual(library("how many times does \"soul\" appear in the library")?.measure,"total")
        XCTAssertEqual(library("how many times is jazz mentioned across all articles")?.query?.equals,"jazz")
        XCTAssertEqual(library("what links to Atlantic Records")?.query?.linksTo,"Atlantic Records")
        XCTAssertEqual(library("list the articles that contain blues")?.measure,"list")
        XCTAssertEqual(library("how many articles in the library talk about gospel")?.query?.equals,"gospel")
        XCTAssertEqual(library("count the word soul in the linked articles")?.scope,"linked")
        XCTAssertEqual(library("check more articles")?.result,"more")
        XCTAssertNotNil(library("how many articles link to Ray Charles")?.libraryRequest)
    }

    func testPageQuestionsStayOnThePage() {
        // Without a scope these are about the open article, not the library.
        XCTAssertNotEqual(CompanionLocalParser.parse("how many links in this article")?.steps.first?.action,"library")
        XCTAssertNotEqual(CompanionLocalParser.parse("count jazz")?.steps.first?.action,"library","a bare count is never a library question")
        XCTAssertNil(CompanionLocalParser.parse("how many articles mention jazz in the Career section"),"an unclear scope goes to the model")
        XCTAssertNotEqual(CompanionLocalParser.parse("how many articles are there")?.steps.first?.action,"library","grammatical articles on the page")
    }

    func testPlansFromAModel() throws {
        let raw=#"{"steps":[{"action":"count","scope":"all articles","query":{"unit":"phrase","equals":"Atlantic Records"}}],"reply":"Checking."}"#
        let plan=try XCTUnwrap(CompanionPlan.decode(raw)).normalized()
        XCTAssertEqual(plan.steps.first?.action,"library","a count over a scope becomes a library step")
        XCTAssertEqual(plan.steps.first?.scope,"library")
        XCTAssertEqual(plan.steps.first?.measure,"articles")
        XCTAssertTrue(plan.problems.isEmpty,plan.problems.joined(separator:"; "))
        let titles=#"{"steps":[{"action":"library","titles":["Ray Charles","Sam Cooke"],"measure":"times","query":{"unit":"word","equals":"soul"}}],"reply":"Reading both."}"#
        let step=try XCTUnwrap(CompanionPlan.decode(titles)?.normalized().steps.first)
        XCTAssertEqual(step.libraryRequest?.scope,"titles")
        XCTAssertEqual(step.libraryRequest?.measure,"total")
        let bad=#"{"steps":[{"action":"library","measure":"articles","query":{"unit":"word","meaning":"about music"}}],"reply":"x"}"#
        XCTAssertFalse(try XCTUnwrap(CompanionPlan.decode(bad)).normalized().problems.isEmpty,"meaning can't run across the library")
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"linksTo\""))
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"measure\""))
    }
}

final class ConnectParserTests:XCTestCase {
    private func connect(_ request:String,file:StaticString=#filePath,line:UInt=#line)->CompanionStep? {
        let plan=CompanionLocalParser.parse(request)
        XCTAssertEqual(plan?.steps.first?.action,"connect","“\(request)” should connect two articles",file:file,line:line)
        XCTAssertEqual(plan?.local,true,file:file,line:line)
        return plan?.steps.first
    }

    func testTwoArticles() {
        for request in ["How is Ray Charles connected to Paris?","how is Ray Charles linked to Paris","how does Ray Charles connect to Paris",
                        "how are Ray Charles and Paris connected","how are Ray Charles and Paris linked to each other","how do Ray Charles and Paris connect",
                        "connect Ray Charles to Paris","connect Ray Charles and Paris","connect the dots between Ray Charles and Paris",
                        "find the shortest path from Ray Charles to Paris","path from Ray Charles to Paris","what's the connection between Ray Charles and Paris",
                        "how do I get from Ray Charles to Paris","how to get from Ray Charles to Paris","six degrees from Ray Charles to Paris",
                        "what connects Ray Charles and Paris","trace the chain of links from Ray Charles to Paris","please connect Ray Charles to Paris"] {
            let step=connect(request)
            XCTAssertEqual(step?.from,"Ray Charles",request)
            XCTAssertEqual(step?.title,"Paris",request)
            XCTAssertTrue(step?.problems.isEmpty == true,request)
        }
    }

    func testFromTheOpenArticle() {
        for request in ["how is this article connected to the Moon","connect this to the Moon","connect to the Moon","find a path to the Moon",
                        "how do I get from here to the Moon","how is this connected to the Moon"] {
            let step=connect(request)
            XCTAssertNil(step?.from,request)
            XCTAssertEqual(step?.title,"the Moon",request)
        }
    }

    func testQuotedTitlesAndContinuing() {
        let quoted=connect("connect \"Simon and Garfunkel\" to \"Welcome to the Jungle\"")
        XCTAssertEqual(quoted?.from,"Simon and Garfunkel","the user's own capitalization")
        XCTAssertEqual(quoted?.title,"Welcome to the Jungle")
        // The last "and" separates the two, so a title can contain one.
        XCTAssertEqual(connect("how are Simon and Garfunkel and Paris connected")?.from,"Simon and Garfunkel")
        XCTAssertEqual(connect("keep looking")?.result,"more")
        XCTAssertEqual(connect("look for a shorter path")?.result,"more")
    }

    func testOtherRequestsAreLeftAlone() {
        XCTAssertEqual(CompanionLocalParser.parse("what links to Paris")?.steps.first?.action,"library","a library question")
        XCTAssertNotEqual(CompanionLocalParser.parse("find links to Paris")?.steps.first?.action,"connect")
        XCTAssertNotEqual(CompanionLocalParser.parse("go to the Early life section")?.steps.first?.action,"connect")
        XCTAssertNil(CompanionLocalParser.parse("how is Paris related to France"),"relations are a question for the model")
        XCTAssertNil(CompanionLocalParser.parse("connect Paris to here"),"the target has to be named")
    }

    func testPlansFromAModel() throws {
        let raw=#"{"steps":[{"action":"six degrees","titles":["Ray Charles","Paris"]}],"reply":"Let me look."}"#
        let step=try XCTUnwrap(CompanionPlan.decode(raw)?.normalized().steps.first)
        XCTAssertEqual(step.action,"connect")
        XCTAssertEqual(step.from,"Ray Charles");XCTAssertEqual(step.title,"Paris")
        XCTAssertTrue(step.problems.isEmpty,step.problems.joined(separator:"; "))
        let missing=#"{"steps":[{"action":"connect"}],"reply":"x"}"#
        XCTAssertFalse(try XCTUnwrap(CompanionPlan.decode(missing)).normalized().problems.isEmpty,"connect needs a target")
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"from\""))
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"connect\""))
    }
}

final class LinkMapParserTests:XCTestCase {
    private func step(_ request:String,file:StaticString=#filePath,line:UInt=#line)->CompanionStep? {
        let plan=CompanionLocalParser.parse(request)
        XCTAssertEqual(plan?.local,true,"“\(request)” should be understood instantly",file:file,line:line)
        return plan?.steps.first
    }

    func testWhatLinksHere() {
        for (request,measure) in [("what links here","list"),("What links here?","list"),("which articles link here","list"),("how many articles link here","articles"),
                                  ("which pages link to this article","list"),("what links to this page","list")] {
            let found=step(request)
            XCTAssertEqual(found?.action,"library",request)
            XCTAssertEqual(found?.measure,measure,request)
            XCTAssertEqual(found?.query?.linksTo.map {ConnectionEngine.isOpenArticle($0)},true,request)
            XCTAssertEqual(found?.libraryRequest?.linksHereTarget.map {ConnectionEngine.isOpenArticle($0)},true,request)
        }
        XCTAssertEqual(step("which articles link to Paris")?.libraryRequest?.linksHereTarget,"Paris")
    }

    func testArticlesInACategory() {
        for (request,measure) in [("how many articles are in the category Jazz pianists","articles"),("How many pages are there in Category:Jazz pianists?","articles"),
                                  ("how many articles does the Jazz pianists category have","articles"),("which articles are in the category Jazz pianists","list"),
                                  ("list the articles in the Jazz pianists category","list"),("what's in Category:Jazz pianists","list"),
                                  ("show me all pages in category Jazz pianists","list"),("which articles belong to the category \"Jazz pianists\"","list")] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertEqual(found?.title,"Jazz pianists",request)
            XCTAssertEqual(found?.measure,measure,request)
            XCTAssertTrue(found?.problems.isEmpty == true,request)
        }
    }

    func testCategoriesOfAnArticle() {
        for request in ["what categories is this article in","What categories is this in?","which categories is it in","list the categories",
                        "what are the categories of this article","what categories does this page belong to"] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertNil(found?.title,request)
            XCTAssertNil(found?.from,request)
        }
        for request in ["what categories is Ray Charles in","what categories does Ray Charles belong to","list the categories of Ray Charles"] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertEqual(found?.from,"Ray Charles",request)
        }
    }

    func testSubcategories() {
        for request in ["how many articles are in the category Jazz musicians including subcategories","How many articles are in Jazz musicians and its subcategories?",
                        "which articles are in Category:Jazz musicians or any of its subcategories","list the articles in the Jazz musicians category including sub-categories",
                        "how many pages are in category Jazz musicians, counting subcategories"] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertEqual(found?.title,"Jazz musicians",request)
            XCTAssertEqual(found?.subcategories,true,request)
            XCTAssertTrue(found?.problems.isEmpty == true,request)
        }
        XCTAssertNil(step("how many articles are in the category Jazz musicians")?.subcategories,"only when asked")
        for request in ["what are the subcategories of Jazz musicians","list the subcategories of Category:Jazz musicians","which subcategories does Jazz musicians have",
                        "how many subcategories does the Jazz musicians category have","show me the sub categories of Jazz musicians","subcategories of Jazz musicians"] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertEqual(found?.title,"Jazz musicians",request)
            XCTAssertEqual(found?.measure,"subcategories",request)
        }
        for request in ["what are the parent categories of Jazz pianists","which categories contain the category Jazz pianists","what categories is the category Jazz pianists in"] {
            let found=step(request)
            XCTAssertEqual(found?.action,"category",request)
            XCTAssertEqual(found?.title,"Jazz pianists",request)
            XCTAssertEqual(found?.measure,"parents",request)
        }
    }

    func testOtherLanguages() {
        for (request,measure,language,from) in [("what is this article called in French","name","French",nil),("What's this called in Japanese?","name","Japanese",nil),
                                                ("what is Paris called in German","name","German","Paris"),("what is the French title of this article","name","French",nil),
                                                ("is this article available in Spanish","name","Spanish",nil),
                                                ("which languages is this article in","list",nil,nil),("what other languages is Ray Charles available in","list",nil,"Ray Charles"),
                                                ("in which languages is this article","list",nil,nil),("other languages","list",nil,nil),
                                                ("open this in French","open","French",nil),("read this article in German","open","German",nil),("switch to French","open","French",nil),
                                                ("open the Japanese version","open","Japanese",nil),("open the French version of Ray Charles","open","French","Ray Charles"),
                                                ("open Paris in French","open","French","Paris"),("show me this in Simple English","open","Simple English",nil),
                                                ("go to the German version","open","German",nil)] as [(String,String,String?,String?)] {
            let found=step(request)
            XCTAssertEqual(found?.action,"language",request)
            XCTAssertEqual(found?.measure,measure,request)
            XCTAssertEqual(found?.language,language,request)
            XCTAssertEqual(found?.from,from,request)
            XCTAssertTrue(found?.problems.isEmpty == true,"\(request): \(found?.problems ?? [])")
        }
        // Not language requests: no language, or not about the article.
        for request in ["open this in a new window","show me the nouns in French","highlight the verbs in green","what is this called"] {
            XCTAssertNotEqual(CompanionLocalParser.parse(request)?.steps.first?.action,"language",request)
        }
        var model=CompanionStep(action:"other languages");model.place="French";model.measure="read it"
        XCTAssertEqual(model.normalized()?.action,"language")
        XCTAssertEqual(model.normalized()?.language,"French")
        XCTAssertEqual(model.normalized()?.measure,"open")
        var open=CompanionStep(action:"language");open.measure="open"
        XCTAssertFalse(open.problems.isEmpty,"opening needs the language")
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"subcategories\""))
        XCTAssertTrue(CompanionPlan.schemaJSON.contains("\"parents\",\"name\",\"open\""))
    }

    func testOtherQuestionsAreNotCategoryQuestions() {
        XCTAssertEqual(CompanionLocalParser.parse("how many articles mention Atlantic Records")?.steps.first?.action,"library")
        XCTAssertEqual(CompanionLocalParser.parse("which articles link to Paris")?.steps.first?.action,"library")
        XCTAssertNil(CompanionLocalParser.parse("which category has the most articles"))
        XCTAssertNil(CompanionLocalParser.parse("how many articles are in the library"))
        var model=CompanionStep(action:"categories");model.title="Category:Jazz pianists"
        XCTAssertEqual(model.normalized()?.action,"category")
        XCTAssertEqual(model.normalized()?.title,"Jazz pianists")
    }
}
