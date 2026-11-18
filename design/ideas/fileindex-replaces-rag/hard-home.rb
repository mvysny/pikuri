# frozen_string_literal: true

# Q_transcript_bar, round 2: a Documents folder where browsing doesn't find the answer, so the
# eval's pass rate measures search. The demo home's 13 documents (built by dev/demo-home/build into
# ~/Documents) are copied in under the names real files get (scanner names, portal downloads),
# among ~250 generated distractors: near-misses that share each task's words but answer
# differently (a paid older invoice, last year's policy, the previous flat's lease, board
# minutes that discuss the move without deciding it), and bulk. The workspace's boot snapshot
# still shows the top level, as it would for a real folder (its 2 KB cap is twice a real $HOME's);
# what it can't show is which of 40 scans or 4 policies holds the answer.
#
#   bundle exec ruby design/ideas/fileindex-replaces-rag/hard-home.rb [TARGET]
#
# TARGET defaults to ~/pikuri-eval/Documents: outside any git checkout, so localsearch indexes it
# (its stock config covers all of $HOME). Rebuilds only a folder it marked. Writes gold.json
# beside TARGET (never inside it, where the agent could read it): each task's file basename.
# Seeded, so every build is the same.

require 'fileutils'
require 'json'

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../../Gemfile', __dir__)
require 'bundler/setup'
require 'pikuri-core'
require_relative '../../../dev/demo-home/builder/converter'

DEMO = File.expand_path('~/Documents')
TARGET = File.expand_path(ARGV[0] || '~/pikuri-eval/Documents')
MARKER = '.pikuri-eval'
RNG = Random.new(20_261_118)
CONVERTER = Pikuri::Demo::Converter.shared

abort "#{DEMO} is not the demo home: run dev/demo-home/build first" unless File.file?(File.join(DEMO, '.pikuri-demo'))
if File.exist?(TARGET)
  abort "#{TARGET} exists and isn't a pikuri eval home (no #{MARKER}); refusing" unless File.file?(File.join(TARGET, MARKER))
  FileUtils.rm_rf(TARGET)
end
FileUtils.mkdir_p(TARGET)
File.write(File.join(TARGET, MARKER), "A pikuri eval home. Holds no real files.\n")

def pick(list) = list[RNG.rand(list.size)]
def put(rel, bytes) = File.binwrite(File.join(TARGET, rel).tap { FileUtils.mkdir_p(File.dirname(_1)) }, bytes)

def copy(from, to)
  put(to, File.binread(File.join(DEMO, from)))
  File.basename(to)
end

# A titled document: Markdown or text as written, HTML wrapped, PDF/DOCX/ODT through LibreOffice.
def doc(rel, title, paragraphs)
  case File.extname(rel)
  when '.md' then put(rel, "# #{title}\n\n#{paragraphs.join("\n\n")}\n")
  when '.txt' then put(rel, "#{title}\n\n#{paragraphs.join("\n\n")}\n")
  else
    html = "<html><head><title>#{title}</title></head><body><h1>#{title}</h1>" \
           "#{paragraphs.map { "<p>#{_1}</p>" }.join}</body></html>"
    ext = File.extname(rel).delete('.')
    put(rel, ext == 'html' ? html : CONVERTER.convert(html, ext))
  end
end

# --- the demo documents, renamed and buried --------------------------------------------------------
gold = {
  'invoice' => copy('Finance/invoice-4471.pdf', 'Scans/scan_20261009_002.pdf'),
  'notice' => copy('Housing/lease-agreement.pdf', 'Scans/scan_20250301_001.pdf'),
  'flood' => copy('Insurance/home-insurance-policy.pdf', 'Archive/2026/policy_HX-99231.pdf'),
  'sauna' => copy('sauna-stove-guide.html', 'Saved web pages/Choosing a wood-burning sauna stove.html'),
  'solar' => copy('Notes/house.md', 'Notes/cottage.md'),
  'office' => copy('Work/meeting-notes-board.pdf', 'Work/Board/2026-10-21.pdf'),
  'electricity' => copy('budget.csv', 'Finance/spreadsheets/budget-2026.csv'),
  'dentist' => copy('Notes/dentist.md', 'Notes/appointments.md'),
  'finnish-rent' => 'scan_20250301_001.pdf',
  'bike-lock' => 'bike-lock.md'
}
copy('Housing/lease-agreement.odt', 'Archive/2025/Lease_final_signed.odt')
copy('Work/meeting-notes-board.docx', 'Work/Board/2026-10-21.docx')
copy('Recipes/grandmas-pulla.txt', 'Recipes/pulla.txt')
copy('Books/the-agent-handbook.pdf', 'Books/the-agent-handbook.pdf')
copy('scan-receipt.png', 'Scans/scan_20261012_001.png')

# --- near-misses: each task's words, another answer ----------------------------------------------
doc('Scans/scan_20260512_001.pdf', 'Kettle & Co. — Invoice #4398', [
  'Issued: 2026-05-12 · Due: 2026-06-11', 'Bill to: Alex Novak, Kalevankatu 14 B 22, 00100 Helsinki',
  'Kettle descaling service, 1 × EUR 117.50; Replacement lid, 2 l kettle, 1 × EUR 34.00',
  'Total due: EUR 151.50', 'Pay to IBAN FI21 1234 5600 0007 85, reference 43980.',
  'PAID 2026-06-02 — thank you for your payment.'
])
doc('Archive/2025/policy_HX-88120.pdf', 'Home Insurance Policy HX-88120', [
  'Insurer: Revontuli Mutual. Policyholder: Alex Novak.', 'Coverage period: 2025-01-01 to 2025-12-31.',
  'Deductible: the deductible for water damage is EUR 400.00. For theft and burglary the deductible is EUR 150.00.',
  'Claims: report a claim within 30 days by calling +358 10 555 0199.', 'This policy has expired and was replaced by policy HX-99231.'
])
doc('Archive/2026/policy_CX-40217.pdf', 'Motor Insurance Policy CX-40217', [
  'Insurer: Revontuli Mutual. Vehicle: Skoda Octavia, registration ZKN-482.', 'Coverage period: 2026-03-01 to 2027-02-28.',
  'Deductible for collision damage: EUR 300.00. Glass damage: EUR 0.00.',
  'Flood or water damage to the vehicle is covered under comprehensive cover, deductible EUR 300.00.',
  'Report a claim within 7 days through the online service.'
])
doc('Archive/2026/policy_TR-7730.pdf', 'Travel Insurance Policy TR-7730', [
  'Insurer: Revontuli Mutual. Insured: Alex Novak.', 'Valid for trips of up to 45 days, 2026-01-01 to 2026-12-31.',
  'Deductible for medical expenses: EUR 50.00. Deductible for luggage damage: EUR 100.00.',
  'Report a claim within 6 months of the end of the trip.'
])
doc('Archive/2024/Lease_Tampere_Satakunnankatu.pdf', 'Residential Lease Agreement', [
  'Landlord: Kiinteistö Oy Satakunta. Tenant: Alex Novak.', 'Premises: Satakunnankatu 7 A 3, 33100 Tampere.',
  '1. Rent. Monthly rent is EUR 890.00, due on the 1st day of each month.',
  "2. Notice period. The tenant may terminate this lease with two (2) calendar months' notice.",
  '3. Deposit. EUR 1,780.00.', 'Lease ended 2025-02-28. Deposit returned 2025-03-20.'
])
doc('Scans/scan_20250415_001.pdf', 'Parking Space Rental Agreement', [
  'Lessor: As Oy Kalevankatu 14. Lessee: Alex Novak.', 'Space: P-12, garage level -1.',
  'Rent EUR 95.00 per month, due on the 5th day of each month.',
  "Either party may terminate this agreement with fourteen (14) days' notice."
])
doc('Scans/scan_20250820_001.pdf', 'Gym membership terms — Kuntokeskus Kallio', [
  'Member: Alex Novak. Membership type: Standard, EUR 49.00 per month.',
  'Cancellation: the membership can be cancelled with 14 days notice; the cancellation takes effect at the end of the notice period.'
])
doc('Archive/2025/service-agreement-lumo-studio.pdf', 'Service agreement — Novak Design and Lumo Studio', [
  'Lumo Studio provides illustration services to Novak Design.', "Either party may terminate this agreement with three (3) months' written notice.",
  'Invoices are payable within 21 days.'
])
doc('Saved web pages/Electric sauna heaters for small rooms.html', 'Electric sauna heaters for small rooms', [
  'Home | Shop | Contact', 'For a small sauna of up to 6 cubic metres, an electric heater of 4.5 kW heats the room in about 40 minutes.',
  'Electric heaters need a dedicated 3-phase circuit installed by an electrician.'
])
doc('Saved web pages/Sauna stones how often to replace.html', 'Sauna stones: how often to replace them', [
  'Stones crack with use. Check them once a year and replace the crumbling ones.', 'Use only stones sold for saunas, such as olivine diabase.'
])
doc('Saved web pages/Loyly etiquette.html', 'Löyly etiquette for beginners', [
  'Ask before throwing water on the stove. Sit on a towel. Cool down between rounds.'
])
doc('Notes/solar-quote-flat.md', 'Solar quote for the flat', [
  'Aurinkovoima Oy quoted EUR 2,900 for four balcony panels at Kalevankatu, 2026-04.',
  'Declined: the housing company does not allow panels on the balcony railing.'
])
doc('Notes/cottage-todo.md', 'Cottage to-do', ['Check the inverter display after winter.', 'Clear the gutters.', 'Order firewood, 6 m³.'])
doc('Notes/health.md', 'Health', [
  'Dentist (Dr. Laine, Hammasklinikka Tähti): checkups done 2025-06-10 and 2025-12-02.',
  'Eye test 2026-03-15: no change.', 'Flu shot in October.'
])
doc('Scans/scan_20250610_001.pdf', 'Hammasklinikka Tähti — price list', [
  'Checkup EUR 65. Cleaning EUR 85. X-ray EUR 35. Book an appointment at ajanvaraus@tahti-klinikka.example.'
])
doc('Notes/codes.md', 'Codes', ['Garage door: 5521.', 'Cottage key box: 0907.', 'Storage unit padlock: 3318.'])
put('Finance/spreadsheets/budget-2025.csv', "month,category,amount_eur\n2025-09,groceries,580\n2025-09,electricity,74\n" \
                                            "2025-10,groceries,602\n2025-10,electricity,97\n2025-11,electricity,118\n")
put('Finance/spreadsheets/savings.csv', "month,account,balance_eur\n2026-08,savings,8200\n2026-09,savings,8650\n2026-10,savings,8900\n")
put('Finance/spreadsheets/car-costs.csv', "date,item,amount_eur\n2026-03-02,insurance,412\n2026-05-14,service,286\n2026-09-30,tyres,540\n")

PEOPLE = %w[Alex Ilse Tomas].freeze
TOPICS = ['the hiring plan', 'the Q4 budget', 'the client portfolio review', 'the website relaunch', 'the offsite agenda',
          'office options: staying in Helsinki, Turku or Tampere', 'pricing for the Lumo Studio work', 'the year-end party',
          'the design system migration', 'invoicing delays'].freeze
%w[2025-01-14 2025-02-18 2025-03-18 2025-04-15 2025-05-20 2025-06-17 2025-08-19 2025-09-16 2025-10-21 2025-11-18
   2025-12-16 2026-01-20 2026-02-17 2026-03-17 2026-04-21 2026-05-19 2026-06-16 2026-08-18 2026-09-15].each do |date|
  items = [pick(TOPICS), pick(TOPICS), pick(TOPICS)].uniq.map { "Discussed #{_1}." }
  items << 'Office move: Turku and Tampere both shortlisted; decision postponed to the October meeting.' if date >= '2026-06'
  doc("Work/Board/#{date}.md", "Board meeting, #{date}", ["Present: #{PEOPLE.join(', ')}.", *items, 'Next meeting in a month.'])
end

# --- bulk ----------------------------------------------------------------------------------------
CLIENTS = ['Lumo Studio', 'Pohjola Bakery', 'Saimaa Boats', 'Kide Ventures', 'Helmi Kindergarten', 'Varjo Games',
           'Nordic Tea House', 'Kallio Cycles'].freeze
CLIENTS.each do |client|
  slug = client.downcase.tr(' ', '-')
  doc("Work/Projects/#{slug}/brief.md", "#{client} — brief", ["Goal: a new #{pick(%w[logo website brochure app])} by #{pick(%w[March May September November])}.",
                                                              "Contact: #{pick(%w[Mira Sami Aino Peter Lea])}. Budget around EUR #{RNG.rand(2..20)},000."])
  doc("Work/Projects/#{slug}/notes.md", "#{client} — notes", ["Kickoff went well.", "Feedback round #{RNG.rand(1..3)}: #{pick(['more contrast', 'simpler layout', 'warmer colours', 'bigger type'])}.",
                                                              "Next: #{pick(['send invoice', 'second draft', 'final files', 'user testing'])}."])
  doc("Work/Projects/#{slug}/proposal.pdf", "Proposal for #{client}", ['Scope, timeline and price as discussed.', "Fixed price EUR #{RNG.rand(3..25)},#{RNG.rand(100..999)}.",
                                                                       'Payment within 14 days of each milestone invoice.'])
end

VENDORS = ['Verkkokauppa', 'K-Rauta', 'Tokmanni', 'Clas Ohlson', 'Gigantti', 'Stockmann', 'Prisma', 'Motonet'].freeze
GOODS = ['headphones', 'a drill', 'paint, 3 l', 'a bookshelf', 'a coffee grinder', 'winter tyres', 'a desk lamp', 'a router',
         'garden hose', 'a vacuum cleaner', 'bed linen', 'a printer'].freeze
30.times do |i|
  date = format('20%02d-%02d-%02d', RNG.rand(24..26), RNG.rand(1..12), RNG.rand(1..28))
  vendor = pick(VENDORS)
  what = pick(GOODS)
  price = format('%d.%02d', RNG.rand(9..450), RNG.rand(0..99))
  body = ["#{vendor}, #{date}.", "Bought #{what}: EUR #{price}.", "Paid by card. Warranty #{pick([12, 24, 36])} months."]
  if i < 12
    doc("Scans/scan_#{date.delete('-')}_#{format('%03d', 10 + i)}.pdf", "Receipt — #{vendor}", body)
  else
    doc("Archive/20#{date[2, 2]}/order-#{RNG.rand(100_000..999_999)}.txt", "Order confirmation — #{vendor}", body)
  end
end

LETTERS = [['As Oy Kalevankatu 14', 'Water will be shut off', 'The water will be shut off on %s from 9 to 15 for pipe work.'],
           ['As Oy Kalevankatu 14', 'Annual general meeting', 'The annual general meeting is held on %s at 18:00 in the club room.'],
           ['As Oy Kalevankatu 14', 'Sauna turns', 'Shared sauna turns for %s onwards: book in the stairwell list.'],
           ['Northwind Bank', 'Change to service fees', 'From %s the monthly account fee is EUR 3.50.'],
           ['Tax Administration', 'Tax decision summary', 'Your tax decision for the year is ready; refund paid on %s.'],
           ['Helsinki City', 'Parking permit', 'Your resident parking permit is valid until %s.']].freeze
LETTERS.each_with_index do |(from, title, text), i|
  date = format('2026-%02d-%02d', RNG.rand(1..10), RNG.rand(1..28))
  doc("Scans/scan_#{date.delete('-')}_#{format('%03d', 40 + i)}.pdf", "#{from}: #{title}", [format(text, date)])
end

NOTE_TOPICS = {
  'books' => ['Books to read', ['The Overstory', 'Piranesi', 'Kalevala, new translation', 'A Psalm for the Wild-Built']],
  'gifts' => ['Gift ideas', ['Ilse: tea sampler', 'Tomas: bike light', 'Peter: Finnish coffee', 'Mira: sketchbook']],
  'car' => ['Car', ['Service every 30,000 km', 'Winter tyres in the garage', 'Next inspection 2027-03']],
  'plants' => ['Plants', ['Water the monstera weekly', 'Repot the fig in spring', 'Basil needs more light']],
  'travel-2027' => ['Travel 2027', ['Lapland in March', 'Bratislava to see Peter', 'Maybe Iceland in summer']],
  'packing-list' => ['Packing list', ['Passport', 'Chargers', 'Rain jacket', 'Sauna towel']],
  'ideas' => ['Ideas', ['Newsletter for clients', 'Workshop on accessible colour', 'Redo the portfolio site']],
  'wifi' => ['Home network', ['Router in the hallway cupboard', 'Guest network: novak-guest']],
  'groceries' => ['Groceries', ['Oat milk', 'Rye bread', 'Cardamom', 'Salmon']],
  'running' => ['Running', ['5 km under 28 min', 'Helsinki half marathon in May']],
  'kalevankatu' => ['Flat', ['Radiator in the bedroom is noisy', 'Balcony door seal needs replacing']],
  'meeting-prep' => ['Meeting prep', ['Bring the budget sheet', 'Ask about the offsite', 'Review the hiring plan']],
  'finnish-words' => ['Finnish words', ['vuokra = rent', 'lasku = invoice', 'kokous = meeting']],
  'birthday' => ['Birthdays', ['Peter 14.2.', 'Ilse 3.7.', 'Tomas 22.9.']],
  'phone-numbers' => ['Phone numbers', ['Plumber: +358 40 555 0102', 'Electrician: +358 40 555 0177']]
}.freeze
NOTE_TOPICS.each { |slug, (title, lines)| doc("Notes/#{slug}.md", title, lines.map { "- #{_1}" }) }
15.times do |i|
  date = format('2026-%02d-%02d', RNG.rand(1..11), RNG.rand(1..28))
  doc("Notes/#{date}-#{i}.md", "Note #{date}", ["Called #{pick(%w[Ilse Tomas Peter Mira Aino])} about #{pick(['the invoice', 'the weekend', 'the cottage', 'the project', 'dinner'])}.",
                                               "Follow up #{pick(['next week', 'on Friday', 'after the holidays', 'tomorrow'])}."])
end

RECIPES = [['Karelian pies', 'rye flour, water, rice porridge, butter', 'Bake at 275 °C for 12 minutes.'],
           ['Salmon soup', 'salmon, potatoes, leek, cream, dill', 'Simmer for 20 minutes.'],
           ['Cinnamon buns (korvapuusti)', 'milk, yeast, flour, sugar, butter, cinnamon', 'Bake at 225 °C for 10 minutes.'],
           ['Blueberry pie', 'blueberries, flour, butter, sugar, quark', 'Bake at 200 °C for 25 minutes.'],
           ['Pea soup', 'dried peas, ham, onion', 'Simmer for 2 hours.'],
           ['Rye bread', 'rye flour, sourdough, salt', 'Bake at 250 °C for 50 minutes.'],
           ['Meatballs', 'minced meat, onion, breadcrumbs, cream', 'Fry for 10 minutes.'],
           ['Mustikkasoppa', 'blueberries, water, sugar, potato starch', 'Bring to a boil.'],
           ['Lohikiusaus', 'salmon, potatoes, onion, cream', 'Bake at 200 °C for 45 minutes.'],
           ['Gingerbread', 'flour, syrup, butter, ginger, cinnamon, cloves', 'Bake at 200 °C for 6 minutes.'],
           ['Beetroot salad', 'beetroot, apple, onion, cream', 'Serve cold.'],
           ['Oat porridge', 'oats, water, salt', 'Cook for 5 minutes.']].freeze
RECIPES.each { |name, what, how| doc("Recipes/#{name.downcase.gsub(/[^a-z]+/, '-').chomp('-')}.txt", name, [what, how]) }

ARTICLES = ['How to brew filter coffee', 'Cycling routes around Helsinki', 'Houseplants that tolerate shade',
            'Finnish cases explained', 'Choosing winter tyres', 'How to descale a kettle', 'Basics of colour theory',
            'Setting up a home office', 'Moving house checklist', 'Bread baking with sourdough', 'Saving on electricity in winter',
            'Freelance invoicing basics', 'Renting a flat in Finland', 'Home insurance explained'].freeze
ARTICLES.each do |title|
  doc("Saved web pages/#{title}.html", title, ['Home | Articles | Contact',
                                               "#{title} — a short guide. #{pick(['Start small.', 'Plan ahead.', 'Ask a professional when unsure.', 'Compare at least three offers.'])}",
                                               pick(['Prices vary by region.', 'This article is not advice for your situation.', 'Updated yearly.'])])
end

LOOSE = ['todo', 'Untitled document', 'notes (2)', 'scan', 'draft', 'copy of draft', 'letter', 'list', 'new', 'tmp',
         'ideas old', 'meeting', 'call notes', 'shopping', 'budget ideas', 'cv-alex-novak', 'portfolio text', 'reminder',
         'questions for the bank', 'quotes', 'old notes', 'misc', 'export', 'Document1', 'Document2', 'readme',
         'to print', 'passwords - old wifi', 'phone backup list', 'printer setup', 'address list', 'xmas cards',
         'garden plan', 'sauna plans', 'bike shops', 'tax questions', 'workshop notes', 'feedback', 'notes from call',
         'recipe to try', 'books lent', 'cottage keys', 'invoice template', 'thank you letter', 'presentation outline'].freeze
LOOSE.each do |name|
  lines = Array.new(RNG.rand(2..5)) { pick(['Call back on Monday.', 'Ask Ilse.', 'Check the price.', 'Done.', 'Remember the receipt.',
                                           'Send to Tomas.', 'Print two copies.', 'Look into this later.', 'Not urgent.']) }
  doc("#{name}.txt", name.capitalize, lines)
end

File.write(File.join(File.dirname(TARGET), 'gold.json'), JSON.pretty_generate(gold))
files = Dir.glob(File.join(TARGET, '**', '*')).select { File.file?(_1) }
puts "Wrote #{files.size} files into #{TARGET}; gold map in #{File.join(File.dirname(TARGET), 'gold.json')}"
