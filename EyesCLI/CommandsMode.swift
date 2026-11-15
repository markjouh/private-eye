import Foundation

/// Checks the voice-command parser against a table of things people actually say.
/// `eyes-cli commands` runs the table; `eyes-cli commands "some sentence" ...` shows how sentences parse.
func runCommandsMode(_ args: [String]) {
    if !args.isEmpty {
        for sentence in args { print(String(describing: Commands.parse(sentence)), "<-", sentence) }
        return
    }
    let cases: [(String, VoiceCommand?)] = [
        // Introducing people
        ("This is Sarah.", .rememberPerson(name: "Sarah")),
        ("this is Sarah", .rememberPerson(name: "Sarah")),
        ("This is Mary Jane", .rememberPerson(name: "Mary Jane")),
        ("That is Tom", .rememberPerson(name: "Tom")),
        ("Remember this person as Sarah", .rememberPerson(name: "Sarah")),
        ("Please remember him as tom", .rememberPerson(name: "Tom")),
        ("Remember this as Jean-Luc", .rememberPerson(name: "Jean-Luc")),
        ("Her name is Priya.", .rememberPerson(name: "Priya")),
        ("His name is omar", .rememberPerson(name: "Omar")),
        ("Meet Daniel", .rememberPerson(name: "Daniel")),
        ("Remember Sarah", .rememberPerson(name: "Sarah")),
        ("This is my friend Sarah", .rememberPerson(name: "Sarah")),
        ("This is my mom", .rememberPerson(name: "Mom")),
        ("Remember that this is Alex", .rememberPerson(name: "Alex")),
        // Trailing speech is not part of the name; second thoughts cancel
        ("This is Dana. Oh wait.", .cancelled),
        ("This is Dana oh wait", .cancelled),
        ("This is Mark like", .rememberPerson(name: "Mark")),
        ("This is Mark Like", .rememberPerson(name: "Mark")),
        ("This is Mark um", .rememberPerson(name: "Mark")),
        ("This is Sarah from work", .rememberPerson(name: "Sarah")),
        ("This is Sarah, my sister", .rememberPerson(name: "Sarah")),
        ("This is my friend, Sarah", .rememberPerson(name: "Sarah")),
        ("This is Dr. Lee", .rememberPerson(name: "Dr Lee")),
        ("This is Tom. He's my roommate.", .rememberPerson(name: "Tom")),
        ("Remember him as tom please", .rememberPerson(name: "Tom")),
        ("Remember this as my water bottle. Thanks.", .rememberBelonging(name: "water bottle")),
        ("Remember this as my water bottle please", .rememberBelonging(name: "water bottle")),
        ("Remember this as my keys, never mind", .cancelled),
        ("Forget Sarah. No wait.", .cancelled),
        ("This is Mark, I mean Mike", .cancelled),
        // Remarks that must not enrol anyone
        ("this is great", nil),
        ("This is a chair", nil),
        ("this is weird", nil),
        ("That is so cool", nil),
        ("this is the kitchen", nil),
        ("remember to buy milk", nil),
        ("meet me at five", nil),
        ("This is it", nil),
        // Belongings
        ("Remember this as my water bottle.", .rememberBelonging(name: "water bottle")),
        ("This is my wallet", .rememberBelonging(name: "wallet")),
        ("These are my keys", .rememberBelonging(name: "keys")),
        ("Remember my backpack", .rememberBelonging(name: "backpack")),
        ("Save this as my blue notebook", .rememberBelonging(name: "blue notebook")),
        ("Here's my laptop", .rememberBelonging(name: "laptop")),
        // Finding belongings
        ("Where is my water bottle?", .findBelonging(name: "water bottle")),
        ("Where's my wallet", .findBelonging(name: "wallet")),
        ("Where are my keys?", .findBelonging(name: "keys")),
        ("Have you seen my keys", .findBelonging(name: "keys")),
        ("Do you see my backpack?", .findBelonging(name: "backpack")),
        ("Can you see my phone anywhere", .findBelonging(name: "phone")),
        ("Where did I leave my wallet?", .findBelonging(name: "wallet")),
        ("Is my laptop here?", .findBelonging(name: "laptop")),
        ("Is my laptop open?", nil),
        ("Where is the door?", nil),
        // Who
        ("Who is this?", .whoIsThis),
        ("Who's that", .whoIsThis),
        ("Who is in front of me?", .whoIsThis),
        ("Who am I talking to?", .whoIsThis),
        ("Do you recognize this person?", .whoIsThis),
        ("Do you know him?", .whoIsThis),
        ("Is this someone I know?", .whoIsThis),
        ("Who do you see?", .whoIsThis),
        ("Can you tell me who this is?", .whoIsThis),
        ("Do you know who that is?", .whoIsThis),
        ("Tell me who's here", .whoIsThis),
        ("Identify this person", .whoIsThis),
        ("Who can you see?", .whoIsThis),
        ("What is this?", nil),
        // The same commands in the other words people use for them
        ("That's Tom", .rememberPerson(name: "Tom")),
        ("Here's Sarah", .rememberPerson(name: "Sarah")),
        ("Her name's Priya", .rememberPerson(name: "Priya")),
        ("He is called Omar", .rememberPerson(name: "Omar")),
        ("Call him Tom", .rememberPerson(name: "Tom")),
        ("Call him later", nil),
        ("That's great", nil),
        ("He's tall", nil),
        ("That's my wallet", .rememberBelonging(name: "wallet")),
        ("It's my turn", nil),
        ("Keep track of my cane", .rememberBelonging(name: "cane")),
        ("Erase Sarah", .forget(name: "Sarah")),
        ("Wipe your memory", .forgetEverything),
        ("Reset everything", .forgetEverything),
        ("Who have you met?", .listMemory),
        ("What's in your memory?", .listMemory),
        ("List the people", .listMemory),
        ("Tell me everyone you know", .listMemory),
        ("Tell me everything", nil),
        ("Open settings", .showMemory),
        ("Can you show me my memories", .showMemory),
        ("Do you have the time?", .tellTime),
        ("What time is it right now?", .tellTime),
        ("Can you tell me the time please", .tellTime),
        ("Hey what time is it", .tellTime),
        ("What's the date today?", .tellDate),
        ("What day of the week is it?", .tellDate),
        ("Can you tell me how far that is?", .howFar),
        ("How many feet to the wall?", .howFar),
        ("Is this one of mine?", .whoseIsThis),
        ("Who does this belong to?", .whoseIsThis),
        ("Disable haptics", .obstacleWarnings(on: false)),
        ("Enable obstacle warnings", .obstacleWarnings(on: true)),
        ("Any sign of my keys?", .findBelonging(name: "keys")),
        // Forgetting and listing
        ("Forget Sarah", .forget(name: "Sarah")),
        ("Forget my water bottle", .forget(name: "Water Bottle")),
        ("Forget about tom", .forget(name: "Tom")),
        ("Forget everyone", .forgetEverything),
        ("Forget everything.", .forgetEverything),
        ("Who do you know?", .listMemory),
        ("What do you remember?", .listMemory),
        // Ownership and the memories screen
        ("Whose bottle is this?", .whoseIsThis),
        ("Whose is this", .whoseIsThis),
        ("Is this mine?", .whoseIsThis),
        ("Is this my water bottle?", .whoseIsThis),
        ("Show memories", .showMemory),
        ("Open my memory", .showMemory),
        ("Show me the menu", nil),
        // The clock
        ("What time is it?", .tellTime),
        ("What's the time", .tellTime),
        ("What day is it?", .tellDate),
        ("What's today's date?", .tellDate),
        ("What time does the store close?", nil),
        ("How far is that?", .howFar),
        ("How far away is the door?", .howFar),
        ("How close am I to the wall?", .howFar),
        ("What's the distance to the chair?", .howFar),
        ("How far along is the download?", .howFar),   // accepted: said aloud at a camera, this is rare
        ("How many chairs are there?", nil),
        // Obstacle warnings
        ("Turn off vibration", .obstacleWarnings(on: false)),
        ("Haptics off", .obstacleWarnings(on: false)),
        ("Stop buzzing", .obstacleWarnings(on: false)),
        ("Turn the obstacle warnings on", .obstacleWarnings(on: true)),
        ("Switch on haptics", .obstacleWarnings(on: true)),
        ("Is the light on?", nil),
        // Watch mode
        ("Tell me when someone sits in the chair", .watch(condition: "someone sits in the chair")),
        ("Tell me when a chair frees up.", .watch(condition: "a chair frees up")),
        ("Let me know when I'm pointing at the cereal", .watch(condition: "I'm pointing at the cereal")),
        ("Please tell me when the bus arrives", .watch(condition: "the bus arrives")),
        ("Alert me if someone comes in please", .watch(condition: "someone comes in")),
        ("Let me know as soon as the elevator opens", .watch(condition: "the elevator opens")),
        ("Watch for my bus", .lookFor(thing: "my bus")),
        ("Keep an eye out for a free table", .lookFor(thing: "a free table")),
        ("Watch for Dana.", .lookFor(thing: "Dana")),
        ("Help me find a chair", .lookFor(thing: "a chair")),
        ("Help me find my water bottle please", .lookFor(thing: "my water bottle")),
        ("Scan for the exit", .lookFor(thing: "the exit")),
        ("Keep looking for my jacket", .lookFor(thing: "my jacket")),
        // Every way of asking for a search starts one. The first six were said on the phone the
        // evening search arrived, before the one phrase that then worked ("Watch for …").
        ("Look for Tom", .lookFor(thing: "Tom")),
        ("Oh my god look for Tom", .lookFor(thing: "Tom")),
        ("Look for my jacket", .lookFor(thing: "my jacket")),
        ("Watch from my jacket", .lookFor(thing: "my jacket")),
        ("Look for a blindfold", .lookFor(thing: "a blindfold")),
        ("Look for a Canon camera", .lookFor(thing: "a Canon camera")),
        ("Find my keys", .lookFor(thing: "my keys")),
        ("Find Tom", .lookFor(thing: "Tom")),
        ("Find me a chair", .lookFor(thing: "a chair")),
        ("Find the exit please", .lookFor(thing: "the exit")),
        ("Search for my wallet", .lookFor(thing: "my wallet")),
        ("Locate the elevator", .lookFor(thing: "the elevator")),
        ("Can you find my phone?", .lookFor(thing: "my phone")),
        ("Could you please look for a trash can", .lookFor(thing: "a trash can")),
        ("Okay so can you help me find the bathroom", .lookFor(thing: "the bathroom")),
        ("I'm looking for the bathroom", .lookFor(thing: "the bathroom")),
        ("I'm trying to find a seat", .lookFor(thing: "a seat")),
        ("I need to find my keys", .lookFor(thing: "my keys")),
        ("I can't find my glasses", .lookFor(thing: "my glasses")),
        ("I lost my water bottle", .lookFor(thing: "my water bottle")),
        ("Let's find Dana", .lookFor(thing: "Dana")),
        ("Go find my jacket", .lookFor(thing: "my jacket")),
        ("Look out for stairs", .lookFor(thing: "stairs")),
        ("Scan the room for a power outlet", .lookFor(thing: "a power outlet")),
        ("Keep your eyes peeled for Sarah", .lookFor(thing: "Sarah")),
        ("Tell me when you see a door", .lookFor(thing: "a door")),
        ("Tell me if you see Dana", .lookFor(thing: "Dana")),
        ("Let me know when you spot my bus", .lookFor(thing: "my bus")),
        ("Watch until the light changes", .watch(condition: "the light changes")),
        ("Watch for when the door opens", .watch(condition: "the door opens")),
        ("Say when the elevator opens", .watch(condition: "the elevator opens")),
        // Not searches: nothing to look for, or a question about the view as it is
        ("Find it", nil),
        ("Look for a second", nil),
        ("Find out what this is", nil),
        ("Look at this", nil),
        ("Look around", nil),
        ("Do you see a chair?", nil),
        ("Is there a chair here?", nil),
        ("What am I looking for?", nil),
        ("Stop watching", .stopWatching),
        ("Stop looking", .stopWatching),
        ("Stop searching for it", .stopWatching),
        ("Can you stop the beeping", .stopWatching),
        ("What are you searching for?", .watchStatus),
        ("Are you still searching?", .watchStatus),
        ("Cancel the search", .stopWatching),
        ("Stop beeping", .stopWatching),
        ("Cancel the watch", .stopWatching),
        ("Stop watching for the bus", .stopWatching),
        ("Never mind the watch", .stopWatching),
        ("What are you watching for?", .watchStatus),
        ("Are you still watching?", .watchStatus),
        ("Forget what you just saw", .forgetRecent),
        ("Clear the buffer", .forgetRecent),
        ("Erase the last 30 seconds", .forgetRecent),
        // Asking to be told something now is a question, not a watch
        ("Tell me the time", .tellTime),
        ("Tell me what this is", nil),
        ("Can you tell me when the store closes?", nil),
        ("Tell me if this is milk", nil),
        ("Can you tell me if this is milk?", nil),
        ("Watch out", nil),
        ("Stop", nil),
        // Ordinary questions
        ("What is in front of me?", nil),
        ("Is it safe to cross?", nil),
        ("Read this to me", nil),
        ("How far is the chair?", .howFar),
        ("What color is my shirt?", nil),
    ]
    var failures = 0
    for (sentence, expected) in cases {
        let got = Commands.parse(sentence)
        if got != expected {
            failures += 1
            print("FAIL  \"\(sentence)\"  expected \(String(describing: expected))  got \(String(describing: got))")
        }
    }
    print("\(cases.count - failures)/\(cases.count) command cases pass")

    // Which questions are answered from the last half minute rather than the frame in view.
    let recallCases: [(String, Bool)] = [
        ("Did someone just walk by?", true), ("Did somebody walk past?", true), ("Has anyone come in?", true),
        ("What just happened?", true), ("What happened?", true), ("What was that?", true), ("Who was that?", true),
        ("Was there a dog?", true), ("Did the bus go by?", true), ("Did a car just pass?", true),
        ("Was someone here a moment ago?", true), ("Who just left?", true), ("What did he do?", true),
        ("Did the door close?", true), ("Did anything change?", true), ("Did they leave?", true),
        // About now, whatever the tense
        ("Did I leave the stove on?", false), ("Is someone there?", false), ("What is this?", false),
        ("Is the door open?", false), ("Who is this?", false), ("What does it say?", false),
        ("Where is the exit?", false), ("Is it safe to cross?", false), ("Do I have my keys?", false),
        ("Has this expired?", false), ("Was this made in Italy?", false), ("How many people are here?", false),
        ("Is there a person in view?", false), ("What am I holding?", false), ("Can you see a chair?", false),
    ]
    var recallFailures = 0
    for (sentence, expected) in recallCases where Recall.isAboutThePast(sentence) != expected {
        recallFailures += 1
        print("FAIL  \"\(sentence)\" is \(expected ? "" : "not ")about the recent past")
    }
    print("\(recallCases.count - recallFailures)/\(recallCases.count) recent-past cases pass")

    let watchCases: [(String, String, String)] = [
        ("someone sits in the chair", "Look at the picture. Can you clearly see that someone sits in the chair?", "Someone sits in the chair."),
        ("I'm pointing at the cereal", "Look at the picture. Can you clearly see that the camera is pointing at the cereal?", "You're pointing at the cereal."),
        ("a chair frees up.", "Look at the picture. Can you clearly see that a chair frees up?", "A chair frees up."),
        ("someone is in front of me", "Look at the picture. Can you clearly see that someone is in front of the camera?", "Someone is in front of you."),
        ("my bus is in view", "Look at the picture. Can you clearly see that the bus is in view?", "Your bus is in view."),
        ("Sarah comes back", "Look at the picture. Can you clearly see that sarah comes back?", "Sarah comes back."),
    ]
    var watchFailures = 0
    for (said, question, spoken) in watchCases {
        guard let condition = WatchCondition(said) else { watchFailures += 1; continue }
        if condition.question() != question || condition.spoken != spoken {
            watchFailures += 1
            print("FAIL  watch \"\(said)\": asked \"\(condition.question())\", spoken \"\(condition.spoken)\"")
        }
    }
    print("\(watchCases.count - watchFailures)/\(watchCases.count) watch wording cases pass")

    // What a search is for, who judges it, and how it is said back.
    let known = ["Dana", "Sarah"], owned = ["water bottle", "jacket"]
    func asked(_ target: SearchTarget?) -> String {
        switch target {
        case .person(let name): "person \(name)"
        case .belonging(let name): "belonging \(name)"
        case .sight(let condition, _): condition.question()
        case nil: "nothing"
        }
    }
    let see = "Look at the picture. Can you clearly see that "
    let thingCases: [(String, String, String, String)] = [
        ("Dana", "person Dana", "Looking for Dana.", "Didn't find Dana."),
        ("dana", "person Dana", "Looking for Dana.", "Didn't find Dana."),
        ("my friend Sarah", "person Sarah", "Looking for Sarah.", "Didn't find Sarah."),
        ("my water bottle", "belonging water bottle", "Looking for your water bottle.", "Didn't find your water bottle."),
        ("water bottle", "belonging water bottle", "Looking for your water bottle.", "Didn't find your water bottle."),
        ("the jacket", "belonging jacket", "Looking for your jacket.", "Didn't find your jacket."),
        // Any water bottle is not the user's own: the model looks, and would take either.
        ("a water bottle", see + "there is a water bottle in view?", "Looking for a water bottle.", "Didn't find a water bottle."),
        ("a chair", see + "there is a chair in view?", "Looking for a chair.", "Didn't find a chair."),
        ("chair", see + "there is a chair in view?", "Looking for a chair.", "Didn't find a chair."),
        ("an exit sign", see + "there is an exit sign in view?", "Looking for an exit sign.", "Didn't find an exit sign."),
        ("the exit", see + "the exit is in view?", "Looking for the exit.", "Didn't find the exit."),
        ("a Canon camera", see + "there is a canon camera in view?", "Looking for a Canon camera.", "Didn't find a Canon camera."),
        ("A Lego brick", see + "there is a lego brick in view?", "Looking for a Lego brick.", "Didn't find a Lego brick."),
        ("my keys", see + "the keys are in view?", "Looking for your keys.", "Didn't find your keys."),
        ("the stairs", see + "the stairs are in view?", "Looking for the stairs.", "Didn't find the stairs."),
        ("my bus", see + "the bus is in view?", "Looking for your bus.", "Didn't find your bus."),
        ("someone", see + "there is a person in view?", "Looking for someone.", "Didn't find someone."),
        ("stairs", see + "there are stairs in view?", "Looking for stairs.", "Didn't find stairs."),
        ("Tom", see + "tom is in view?", "Looking for Tom.", "Didn't find Tom."),
    ]
    var targetFailures = 0
    for (said, judge, starting, notFound) in thingCases {
        let target = SearchTarget.named(said, people: known, belongings: owned)
        if asked(target) != judge || target?.starting != starting || target?.notFound != notFound {
            targetFailures += 1
            print("FAIL  look for \"\(said)\": \(asked(target)); \(target?.starting ?? "-") \(target?.notFound ?? "-")")
        }
    }
    let eventCases: [(String, String, String)] = [
        ("someone sits in the chair", see + "someone sits in the chair?", "Watching for when someone sits in the chair."),
        ("I'm pointing at the cereal", see + "the camera is pointing at the cereal?", "Watching for when you're pointing at the cereal."),
        ("you see Dana", "person Dana", "Looking for Dana."),
        ("Sarah is here", "person Sarah", "Looking for Sarah."),
        ("my water bottle is in view", "belonging water bottle", "Looking for your water bottle."),
        ("a chair frees up", see + "a chair frees up?", "Watching for when a chair frees up."),
        ("you see a door", see + "there is a door in view?", "Looking for a door."),
        ("there's a free table", see + "there is a free table in view?", "Looking for a free table."),
        ("the bus shows up", see + "the bus is in view?", "Looking for the bus."),
        ("Sarah sits down", see + "sarah sits down?", "Watching for when Sarah sits down."),
    ]
    for (said, judge, starting) in eventCases {
        let target = SearchTarget.when(said, people: known, belongings: owned)
        if asked(target) != judge || target?.starting != starting {
            targetFailures += 1
            print("FAIL  tell me when \"\(said)\": \(asked(target)); \(target?.starting ?? "-")")
        }
    }
    // A sure sighting is found at once; unsure ones must come twice running.
    var judge = SightingJudge()
    let sightings: [(Bool, Bool, SightingJudge.Verdict)] = [(false, true, .nothing), (false, false, .nothing), (false, true, .nothing), (false, true, .probablyFound), (true, false, .found)]
    for (sure, unsure, expected) in sightings where judge.saw(sure: sure, unsure: unsure) != expected {
        targetFailures += 1
        print("FAIL  sighting judge at sure \(sure), unsure \(unsure)")
    }
    // The model's answers, as a search weighs them: very sure once, or sure twice running.
    func verdicts(_ answers: [Float], model: String) -> [WatchMonitor.Verdict] {
        var monitor = WatchMonitor(WatchCondition("there is a chair in view")!)
        monitor.policy = .searching(forModel: model)
        return answers.map { monitor.answered($0) }
    }
    let monitorCases: [([Float], String, Int?)] = [
        ([0.1, 0.96], "eyes-ft-v2-Q4_K_M", 1), ([0.1, 0.8, 0.2, 0.75, 0.72], "eyes-ft-v2-Q4_K_M", 4), ([0.1, 0.8, 0.3, 0.6], "eyes-ft-v2-Q4_K_M", nil),
        ([0.1, 0.96, 0.5], "LFM3-VL-2B-QAD-Q4_0", nil), ([0.1, 0.99], "LFM3-VL-2B-QAD-Q4_0", 1), ([0.1, 0.92, 0.95], "LFM3-VL-2B-QAD-Q4_0", 2),
    ]
    for (answers, model, expected) in monitorCases {
        let fired = verdicts(answers, model: model).firstIndex { $0 != .nothing }
        if fired != expected {
            targetFailures += 1
            print("FAIL  \(model) on \(answers): found at \(String(describing: fired)), expected \(String(describing: expected))")
        }
    }
    let targetCount = thingCases.count + eventCases.count + sightings.count + monitorCases.count
    print("\(targetCount - targetFailures)/\(targetCount) search target cases pass")

    let names = ["Sarah", "Tom"]
    let personCases: [(String, String?)] = [
        ("Where is Sarah?", "Sarah"), ("Is Tom here?", "Tom"), ("Do you see sarah", "Sarah"),
        ("What is Sarah wearing?", nil), ("Find Tom", nil), ("Any sign of Tom?", "Tom"), ("Is Sarah around?", "Sarah"), ("Where is the door?", nil), ("Tell me about tomatoes", nil),
    ]
    var personFailures = 0
    for (sentence, expected) in personCases where Commands.personAsked(in: sentence, among: names) != expected {
        personFailures += 1
        print("FAIL  person in \"\(sentence)\"  expected \(String(describing: expected))  got \(String(describing: Commands.personAsked(in: sentence, among: names)))")
    }
    print("\(personCases.count - personFailures)/\(personCases.count) person-question cases pass")

    // Which style of answer a question gets (see AnswerStyle).
    let styleCases: [(String, AnswerStyle.Kind)] = [
        ("Which one is the hand soap?", .pick), ("Which bottle is the dish soap?", .pick), ("Which of these is the shampoo?", .pick),
        ("Which button is my finger on?", .general), ("Which way is the exit?", .locate), ("Which side is the door on?", .locate),
        ("Is the hand soap on the left or right?", .locate), ("Is it open or closed?", .general), ("Is the door open?", .yesNo),
        ("Where is the kettle?", .locate), ("What is this?", .object), ("What am I holding?", .object), ("How many chairs are there?", .count),
        ("What color is the hand soap?", .general), ("Can you tell me what this is?", .object), ("What does the sign say?", .read),
        ("What is in front of me?", .describe), ("What does he look like?", .person),
    ]
    var styleFailures = 0
    for (question, expected) in styleCases where AnswerStyle.kind(of: question) != expected {
        styleFailures += 1
        print("FAIL  style of \"\(question)\"  expected \(expected)  got \(AnswerStyle.kind(of: question))")
    }
    print("\(styleCases.count - styleFailures)/\(styleCases.count) answer-style cases pass")
}
