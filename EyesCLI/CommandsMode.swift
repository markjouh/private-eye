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
        ("Find my keys", .findBelonging(name: "keys")),
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
        ("What is this?", nil),
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

    let names = ["Sarah", "Tom"]
    let personCases: [(String, String?)] = [
        ("Where is Sarah?", "Sarah"), ("Is Tom here?", "Tom"), ("Do you see sarah", "Sarah"),
        ("What is Sarah wearing?", nil), ("Find Tom", "Tom"), ("Is Sarah around?", "Sarah"), ("Where is the door?", nil), ("Tell me about tomatoes", nil),
    ]
    var personFailures = 0
    for (sentence, expected) in personCases where Commands.personAsked(in: sentence, among: names) != expected {
        personFailures += 1
        print("FAIL  person in \"\(sentence)\"  expected \(String(describing: expected))  got \(String(describing: Commands.personAsked(in: sentence, among: names)))")
    }
    print("\(personCases.count - personFailures)/\(personCases.count) person-question cases pass")
}
