import Foundation

/// Mints Cowork-style workspace names.
///
/// Cowork labels each session with a Docker-style `adjective-adjective-scientist` triple —
/// `confident-affectionate-bohr`, `upbeat-beautiful-newton`. The name is not decorative: in
/// VM mode it *is* the working directory (`/sessions/<processName>`), and Claude Desktop's
/// disk janitor deletes any workspace directory whose name appears in no session file. An
/// imported session therefore needs a name that is both well-formed and unused.
public enum ProcessName {
    static let adjectives = [
        "admiring", "adoring", "affectionate", "agitated", "amazing", "awesome", "beautiful",
        "blissful", "bold", "brave", "busy", "charming", "clever", "compassionate", "competent",
        "condescending", "confident", "cool", "cranky", "crazy", "dazzling", "determined",
        "distracted", "dreamy", "eager", "ecstatic", "elastic", "elated", "elegant", "eloquent",
        "epic", "exciting", "fervent", "festive", "flamboyant", "focused", "friendly", "frosty",
        "funny", "gallant", "gifted", "goofy", "gracious", "great", "happy", "hardcore",
        "heuristic", "hopeful", "hungry", "infallible", "inspiring", "intelligent", "interesting",
        "jolly", "jovial", "keen", "kind", "laughing", "loving", "lucid", "magical", "modest",
        "musing", "mystifying", "naughty", "nervous", "nice", "nifty", "nostalgic", "objective",
        "optimistic", "peaceful", "pedantic", "pensive", "practical", "priceless", "quirky",
        "quizzical", "recursing", "relaxed", "reverent", "romantic", "sad", "serene", "sharp",
        "silly", "sleepy", "stoic", "strange", "stupefied", "suspicious", "sweet", "tender",
        "thirsty", "trusting", "unruffled", "upbeat", "vibrant", "vigilant", "vigorous", "wizardly",
        "wonderful", "xenodochial", "youthful", "zealous", "zen",
    ]

    static let scientists = [
        "agnesi", "albattani", "allen", "almeida", "antonelli", "archimedes", "ardinghelli",
        "aryabhata", "austin", "babbage", "banach", "banzai", "bardeen", "bartik", "bassi",
        "beaver", "bell", "benz", "bhabha", "bhaskara", "black", "blackburn", "blackwell", "bohr",
        "booth", "borg", "bose", "bouman", "boyd", "brahmagupta", "brattain", "brown", "buck",
        "burnell", "cannon", "carson", "cartwright", "carver", "cerf", "chandrasekhar",
        "chaplygin", "chatelet", "chatterjee", "chebyshev", "clarke", "cohen", "colden", "cori",
        "cray", "curie", "curran", "darwin", "davinci", "dewdney", "dhawan", "diffie", "dijkstra",
        "dirac", "driscoll", "dubinsky", "easley", "edison", "einstein", "elbakyan", "elgamal",
        "elion", "ellis", "engelbart", "euclid", "euler", "faraday", "feistel", "fermat", "fermi",
        "feynman", "franklin", "gagarin", "galileo", "galois", "ganguly", "gates", "gauss",
        "germain", "goldberg", "goldstine", "goldwasser", "golick", "goodall", "gould", "greider",
        "grothendieck", "haibt", "hamilton", "haslett", "hawking", "heisenberg", "hellman",
        "hermann", "herschel", "hertz", "heyrovsky", "hodgkin", "hofstadter", "hoover", "hopper",
        "hugle", "hypatia", "ishizaka", "jackson", "jang", "jemison", "jennings", "jepsen",
        "johnson", "joliot", "jones", "kalam", "kapitsa", "kare", "keldysh", "keller", "kepler",
        "khayyam", "khorana", "kilby", "kirch", "knuth", "kowalevski", "lalande", "lamarr",
        "lamport", "leakey", "leavitt", "lederberg", "lehmann", "lewin", "lichterman", "liskov",
        "lovelace", "lumiere", "mahavira", "margulis", "matsumoto", "maxwell", "mayer", "mccarthy",
        "mcclintock", "mclaren", "mclean", "mcnulty", "meitner", "mendel", "mendeleev", "meninsky",
        "merkle", "mestorf", "mirzakhani", "montalcini", "moore", "morse", "murdock", "moser",
        "napier", "nash", "neumann", "newton", "nightingale", "nobel", "noether", "northcutt",
        "noyce", "panini", "pare", "pascal", "pasteur", "payne", "perlman", "pike", "poincare",
        "poitras", "proskuriakova", "ptolemy", "raman", "ramanujan", "rhodes", "ride", "ritchie",
        "robinson", "roentgen", "rosalind", "rubin", "saha", "sammet", "sanderson", "satoshi",
        "shamir", "shannon", "shaw", "shirley", "shockley", "shtern", "sinoussi", "snyder",
        "solomon", "spence", "stonebraker", "sutherland", "swanson", "swartz", "swirles",
        "taussig", "tereshkova", "tesla", "tharp", "thompson", "torvalds", "tu", "turing",
        "varahamihira", "vaughan", "villani", "visvesvaraya", "volhard", "wescoff", "wilbur",
        "wiles", "williams", "williamson", "wilson", "wing", "wozniak", "wright", "wu", "yalow",
        "yonath", "zhukovsky",
    ]

    /// A fresh name not present in `taken`.
    ///
    /// Falls back to appending a numeric suffix rather than looping forever, so a store with
    /// an improbable number of collisions still completes.
    public static func mint(avoiding taken: Set<String>) -> String {
        for _ in 0..<512 {
            let candidate = "\(adjectives.randomElement()!)-\(adjectives.randomElement()!)-\(scientists.randomElement()!)"
            if !taken.contains(candidate) { return candidate }
        }
        var counter = 2
        let base = "\(adjectives.randomElement()!)-\(adjectives.randomElement()!)-\(scientists.randomElement()!)"
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }

    /// Every workspace name already in use across an account, including the `agent/` subtree.
    ///
    /// Both the metadata's `processName` and the workspace directory names count: the janitor
    /// reaps a directory whose name no session claims, so a name that is merely *present on
    /// disk* is still unsafe to reuse.
    public static func namesInUse(at accountRoot: URL) -> Set<String> {
        var names: Set<String> = []
        let fm = FileManager.default
        for dir in [accountRoot, accountRoot.appendingPathComponent(StoreLayout.agentSubdirName)] {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.lastPathComponent.hasPrefix(StoreLayout.sessionPrefix) {
                guard entry.pathExtension == "json",
                      let doc = try? MetadataDocument(contentsOf: entry) else { continue }
                if let p = doc.processName { names.insert(p) }
                if let v = doc.vmProcessName { names.insert(v) }
            }
        }
        return names
    }
}
