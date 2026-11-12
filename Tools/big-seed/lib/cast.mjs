// Fernwood, upstream's made-up software company, grown to fifty people, with the names an app gets wrong:
// people who share a name, with and without pictures, very long names, a name of one letter, emoji in
// names, right-to-left and CJK names. Everyone's address is on fernwood.example, which RFC 2606 keeps for
// examples, so no email can reach anyone.

export const DOMAIN = "fernwood.example";

/** The longest name Ember takes is 100 characters; this one is exactly that long. */
const HUNDRED = "Bartholomew Alexander Montgomery-Fitzwilliam Vanderbilt-Ashcombe of Upper Fernwood Lane, Esquire III";

const BIO_200 = ("Writes the release notes nobody reads, reads the ones nobody writes, and keeps a spreadsheet of every typo " +
  "ever shipped in a Fernwood changelog. Fond of ferns, footnotes and long walks.").slice(0, 200);

/**
 * The people: a key the seed knows them by, their name, a bio, and their picture: a file in files/, a
 * number to draw one from, or none for their initials.
 */
export const PEOPLE = [
  { key: "maya", name: "Maya Chen", bio: "Product lead. Ask me about the roadmap.", avatar: "maya.png" },
  { key: "sam", name: "Sam Rivera", bio: "Backend and infrastructure. Probably deploying something.", avatar: "sam.png" },
  { key: "priya", name: "Priya Patel", bio: "Design systems, type and the occasional illustration.", avatar: "priya.png" },
  { key: "leo", name: "Leo Park", bio: "Front end. Will trade code reviews for coffee.", avatar: "leo.png" },
  { key: "jordan", name: "Jordan Lee", bio: "Marketing and community." },
  { key: "amara", name: "Amara Okafor", bio: "Support lead, here for the customers.", avatar: "amara.png" },
  { key: "tomas", name: "Tomás García", bio: "QA and releases. Hiking most weekends.", avatar: "tomas.jpg" },
  // Three sets of people who share a name.
  { key: "sam2", name: "Sam Rivera", bio: "The other Sam. Sales, Lisbon office." },
  { key: "alex1", name: "Alex Kim", bio: "Alex from iOS.", avatar: 101 },
  { key: "alex2", name: "Alex Kim", bio: "Alex from finance. Not the iOS one.", avatar: 202 },
  { key: "alex3", name: "Alex Kim", bio: "" },
  { key: "maria1", name: "Maria Rossi", bio: "Data. Charts with honest axes." },
  { key: "maria2", name: "Maria Rossi", bio: "Office manager, Milan.", avatar: 303 },
  // Names that are long, short, or not in Latin letters.
  { key: "bart", name: HUNDRED, bio: BIO_200, avatar: 404 },
  { key: "hubert", name: "Hubert Blaine Wolfeschlegelsteinhausenbergerdorffvoralternwarengewissenhaft", bio: "Yes, really." },
  { key: "bea", name: "Bea 🌻 Okonkwo", bio: "Gardens, growth marketing, 🌻🌻🌻", avatar: 505 },
  { key: "ravi", name: "Ravi 🚀", bio: "Ships things." },
  { key: "fox", name: "🦊", bio: "A fox. Prefers not to say more.", avatar: 606 },
  { key: "nour", name: "نور الهدى", bio: "مهندسة برمجيات في فريق المنصة", avatar: 707 },
  { key: "yael", name: "יעל כהן", bio: "מעצבת מוצר" },
  { key: "hanako", name: "山田 花子", bio: "東京オフィスのエンジニア", avatar: 808 },
  { key: "jiwoo", name: "김지우", bio: "서울에서 일해요" },
  { key: "zoe", name: "Zoë Ångström-Ñúñez", bio: "Diacritics enthusiast.", avatar: 909 },
  { key: "siobhan", name: "Siobhán O'Brien", bio: "Legal. Reads the terms so you don't have to." },
  { key: "ana", name: "Ana", bio: "", avatar: 111 },
  { key: "x", name: "X", bio: "One letter is plenty." },
  // Everyone else.
  { key: "ben", name: "Ben Carter", bio: "Android.", avatar: 121 },
  { key: "chloe", name: "Chloé Dubois", bio: "Support, Paris." },
  { key: "dev", name: "Dev Malhotra", bio: "Infra and on-call.", avatar: 131 },
  { key: "elena", name: "Elena Petrova", bio: "Security." },
  { key: "finn", name: "Finn Murphy", bio: "Sales engineering.", avatar: 141 },
  { key: "grace", name: "Grace Liu", bio: "Design, motion." },
  { key: "hugo", name: "Hugo Martin", bio: "Backend.", avatar: 151 },
  { key: "isla", name: "Isla Thompson", bio: "People team." },
  { key: "jamal", name: "Jamal Wright", bio: "Front end.", avatar: 161 },
  { key: "kenji", name: "Kenji Watanabe", bio: "Search and indexing." },
  { key: "lena", name: "Lena Fischer", bio: "QA.", avatar: 171 },
  { key: "mateo", name: "Mateo Silva", bio: "Partnerships." },
  { key: "nina", name: "Nina Kowalski", bio: "Docs and DX.", avatar: 181 },
  { key: "omar", name: "Omar Haddad", bio: "Data engineering." },
  { key: "paula", name: "Paula Santos", bio: "Customer success.", avatar: 191 },
  { key: "quinn", name: "Quinn Taylor", bio: "Recruiting." },
  { key: "rosa", name: "Rosa Jiménez", bio: "Finance.", avatar: 212 },
  { key: "sven", name: "Sven Larsen", bio: "Platform." },
  { key: "tara", name: "Tara Singh", bio: "iOS.", avatar: 222 },
  { key: "uma", name: "Uma Nair", bio: "ML." },
  { key: "victor", name: "Victor Huang", bio: "Billing.", avatar: 232 },
  { key: "wen", name: "Wen Zhao", bio: "Growth." },
  { key: "yusuf", name: "Yusuf Demir", bio: "SRE.", avatar: 242 },
  { key: "zara", name: "Zara Ahmed", bio: "Community.", avatar: 252 },
].map((person) => ({ ...person, emailAddress: `${emailLocal(person.key)}@${DOMAIN}` }));

if (HUNDRED.length !== 100) throw new Error(`The long name is ${HUNDRED.length} characters, not 100`);

function emailLocal(key) {
  return `big-seed.${key}`;
}

export const BY_KEY = new Map(PEOPLE.map((person) => [person.key, person]));
export const KEYS = PEOPLE.map(({ key }) => key);
