"""Controlled, synthetic utterance-state corpus; no teacher or human-review claims.
Semantic scenarios and their prefixes stay together. Grammar templates and entities
are assigned before expansion. Shared operation vocabulary is inevitable and disclosed.
"""
import csv, hashlib, json, random, re, unicodedata
from collections import Counter, defaultdict
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SEED=722041

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def norm(s): return ' '.join(re.findall(r'\w+',unicodedata.normalize('NFKC',s).casefold()))
# Each template is exclusive to its split. The mode identifies the semantic label
# rule, rather than deriving gold from an executing parser or a model prediction.
TEMPLATES={
 'train': {
 'application':['Open {app}','Launch {app}','Switch to {app}','Quit {app}'],
 'web':['Search for {topic}','Search Google for {topic}','Open https://{domain}'],
 'productivity':['Create a note called {title}','Create reminder {task}','Append to current note {body}','Write current note {body}'],
 'system':['Set volume to {number} percent','Turn the volume down by {number}','Mute the speakers for {number} minutes'],
 'text_file':['Type at cursor {body}','Copy to clipboard {body}','Reveal in finder /tmp/{slug}'],
 'media':['Play {topic} on Spotify','Pause Spotify for {number} minutes','Skip {number} tracks'],
 'other':['Translate the document about {topic}','Schedule a meeting about {topic}','Send an email saying {body}'],
 'dictation':['I wrote about {topic} today','My note is titled {title}','We discussed {task} yesterday','The {app} window looked quiet'],
 'quoted':['The transcript says "open {app}"','I am quoting "search for {topic}"','She said "create reminder {task}"'],
 'negation':['Do not open {app}','Never search for {topic}','Please do not delete {title}'],
 'hypothetical':['If I say open {app}, that is just an example','Would opening {app} be useful tomorrow','We might search for {topic} next week'],
 'ambiguous':['Open whichever editor has {title}','Search for the thing about {topic}','Put {body} in the usual note','Open {fragment}'],
 'correction':['Open {app}, actually open Notes','Search for {topic}, no wait, search for {title}','Create reminder {task}, actually call it {title}'],
 'compound':['Open {app} and search for {topic}','Open Notes and create a note called {title}','Mute and then open {app}'],
 'corrupt':['Oh pen {app}','Search floor {topic}','Create re minder {task}'],
 },
 'calibration': {
 'application':['Please bring {app} to the front','Start the {app} application','Close the application {app}'],
 'web':['Look up {topic} on the web','Visit the website https://{domain}','Find {topic} using DuckDuckGo'],
 'productivity':['Make a new note named {title}','Remind me to {task}','Add this to my current note: {body}'],
 'system':['Change the sound level to {number} percent','Unmute audio after {number} seconds'],
 'text_file':['Insert the words {body}','Replace selected text with {body}','Show the folder /tmp/{slug}'],
 'media':['Resume my Spotify playback for {number} minutes','Find the song {topic}'],
 'other':['Purchase a book about {topic}','Explain the code in {title}'],
 'dictation':['Today I learned something about {topic}','The reminder title was {title}','Using {app} helped with my work'],
 'quoted':['For the record, the phrase was "launch {app}"','A sample command reads "look up {topic}"'],
 'negation':['Keep {app} closed','Cancel the request to search for {topic}'],
 'hypothetical':['Suppose someone asked to launch {app}','Maybe tomorrow we can write about {topic}'],
 'ambiguous':['Bring my other {app} window here','Navigate to that site about {topic}','Create it with the title {title}'],
 'correction':['Start {app}; scratch that, start Firefox','Look up {topic}; correction: look up {title}'],
 'compound':['Start {app}, then mute audio','Visit https://{domain}, then look up {topic}'],
 'corrupt':['Lawn chair {app}','Make a knew knowt named {title}'],
 },
 'test': {
 'application':['Can you activate {app} now','Run the application named {app}','I need you to exit {app}'],
 'web':['Go to https://{domain} now','Use Wikipedia to search for {topic}','Find web results for {topic}'],
 'productivity':['Create note {title}: {body}','Create a reminder called {task}','Write this in the current note: {body}'],
 'system':['Reduce sound to {number} percent','Increase system volume by {number} percent'],
 'text_file':['Copy the following text: {body}','Type the exact phrase {body}','Reveal /tmp/{slug} in Finder'],
 'media':['Stop playing music for {number} minutes','Search Spotify for the track {topic}'],
 'other':['Book a flight for the conference on {topic}','Summarize my document titled {title}'],
 'dictation':['In our journal we mentioned {topic}','The story describes someone using {app}','My search query was {topic}'],
 'quoted':['Here is a quotation: "activate {app}"','The documentation includes "find web results for {topic}"'],
 'negation':['I am not asking you to activate {app}','Avoid making a note about {topic}'],
 'hypothetical':['Imagine asking the assistant to activate {app}','When we next meet, we could discuss {topic}'],
 'ambiguous':['Activate one of my {app} copies','Write {body} there','Find that result about {topic} again'],
 'correction':['Activate {app}; I mean activate Chrome','Find web results for {topic}; instead find {title}'],
 'compound':['Activate {app}; afterwards visit https://{domain}','Create note {title}: {body} and then mute'],
 'corrupt':['Ack tea vate {app}','Fined web resalts four {topic}'],
 }}
# Disjoint entities are semantic scenario groups, not personal/user data.
APPS={
 'train':'Notes|Safari|Preview|Calendar|Mail|Messages|Photos|Music|Terminal|Finder|Calculator|Contacts|Maps|Books|Podcasts|Reminders|Freeform|Keynote|Numbers|Pages|TextEdit|FaceTime|Dictionary|Clock|Weather|Stocks|Home|Voice Memos|System Settings|Activity Monitor|Disk Utility|Photo Booth|Chess|Automator|Console|Shortcuts|Font Book|Grapher|QuickTime Player|Image Capture'.split('|'),
 'calibration':'Firefox|Slack|Zoom|Obsidian|Notion|Discord|Arc|Figma|VLC|Blender|Xcode|Pixelmator'.split('|'),
 'test':'Chrome|Visual Studio Code|Sublime Text|IntelliJ IDEA|PyCharm|Android Studio|Audacity|GarageBand|Logic Pro|Final Cut Pro|DaVinci Resolve|Affinity Photo|Affinity Designer|Adobe Photoshop|Adobe Illustrator|Adobe Acrobat|Microsoft Word|Microsoft Excel|Microsoft PowerPoint|Microsoft Teams'.split('|')}
TOPICS={
 'train':'binary trees|memory ownership|lunar geology|solar panels|urban planning|ocean currents|rail timetables|bird migration|camera lenses|bicycle repairs|coffee roasting|garden irrigation|ancient ceramics|electric motors|cloud formations|forest ecology|optical fibers|bridge design|piano tuning|graph coloring|volcanic rocks|water filtration|cooking rice|photo archives|network protocols|music notation|battery chemistry|language learning|postal routes|train tickets|wind turbines|orchid care|paper recycling|fish habitats|glacier movement|seismic waves|circuit boards|book binding|light pollution|rainfall patterns'.split('|'),
 'calibration':'quasar spectra|ceramic glazes|desert insects|thermal insulation|sailing knots|marine navigation|ink pigments|acoustic treatment|bread fermentation|violin strings|coral bleaching|decimal arithmetic'.split('|'),
 'test':'Swift actors|Ada Lovelace|compiler diagnostics|distributed transactions|thread sanitizers|zero-copy buffers|Malala Yousafzai|José Saramago|Katherine Johnson|telescope mirrors|native dictionaries|assembly language|sodium batteries|risk registers|stained glass|handwritten scripts|aurora forecasts|canal engineering|statistical inference|mountain rescues'.split('|')}

def entities(split,i):
 topic=TOPICS[split][i]; app=APPS[split][i]
 return dict(app=app,topic=topic,title=f'{topic.title()} Journal',task=f'review the {topic} notes',
  body=f'We should check {topic} before the meeting.',domain=f'{split}-{i+1}.example.org',
  slug=topic.replace(' ','-'),number=str(12+i),fragment=app[:max(1,len(app)//2)])

def build():
 rows=[]; seen=set(); removals=Counter()
 for split in ('train','calibration','test'):
  for mode,templates in TEMPLATES[split].items():
   for ti,template in enumerate(templates):
    for i in range(len(APPS[split])):
     text=template.format(**entities(split,i)); family=f'{split}/{mode}/{ti}/{i}'
     actionable=mode not in ('dictation','quoted','negation','hypothetical')
     ambiguous=mode in ('ambiguous','corrupt','other')
     coarse=mode if mode in ('application','web','productivity','system','text_file','media','other') else (
      'application' if mode in ('correction','compound','corrupt') else 'other')
     if mode=='correction':coarse='web' if 'search' in text.lower() or 'look up' in text.lower() or 'web results' in text.lower() else 'productivity' if 'reminder' in text.lower() else 'application'
     if mode=='compound':coarse='other'
     if mode=='corrupt':coarse='web' if 'search' in text.lower() or 'resalts' in text.lower() else 'productivity' if 'minder' in text.lower() or 'knowt' in text.lower() else 'application'
     if mode=='ambiguous':coarse='web' if any(w in text.lower() for w in ('search','navigate','find')) else 'productivity' if any(w in text.lower() for w in ('note','write','title','put')) else 'application'
     # A deliberately truncated name is incomplete even in the base template.
     base_more=mode=='ambiguous' and '{fragment}' in template
     variants=[(text,base_more,ambiguous,'partial_application' if base_more else 'complete')]
     # Intentional incomplete versions are labeled by semantic operation, and
     # retained alongside their complete scenario before splitting.
     words=text.split()
     if mode=='correction':
      cut=re.split(r'(?i)actually|scratch that|correction:|I mean|instead',text)[0]
      variants.append((cut+' actually',True,True,'partial_correction'))
     elif mode in ('compound',):
      variants.append((text+' and',True,True,'trailing_conjunction'))
     elif mode=='application':
      target=entities(split,i)['app']; loc=text.find(target)
      variants.append((text[:loc]+target[:max(1,len(target)//2)],True,True,'partial_application'))
      # Streaming states before the target, then successive app-name characters.
      # Only states with a demonstrably missing slot are positive: an arbitrary
      # prefix of free text could already be a complete user payload.
      header=text[:loc].strip()
      variants.append((header,True,True,'initial_prefix'))
      for length in sorted(set([1,2,3,max(1,len(target)-1)])):
       if length<len(target):variants.append((header+' '+target[:length],True,True,'streaming_prefix'))
     elif mode=='web':
      variants.append((text+' and search for',True,True,'incomplete_web_query'))
      header=template.split('{')[0].strip().rstrip('/')
      # "Open https://" is a missing domain; retain that spelling exactly.
      if 'https://' in template:header=template.split('{')[0].strip()
      variants.append((header,True,True,'initial_prefix'))
     elif mode=='productivity':
      header=template.split('{')[0].strip()
      variants.append((header,True,True,'initial_prefix'))
      variants.append((text+' and create a note called',True,True,'incomplete_note'))
      variants.append((text+' and create reminder',True,True,'incomplete_reminder'))
      # Distinct payload-start prefixes: do not treat the final flag as gold.
      variants.append((text+' and write',True,True,'payload_prefix'))
     elif mode in ('dictation','quoted','negation','hypothetical'):
      variants.append((' '.join(words[:-2])+' because',True,False,'dictation_prefix'))
     else:
      variants.append((text+' and then',True,True,'trailing_conjunction'))
     # Speech states reflect repeated partials / hesitation without counting
     # repeat events as independent evidence in the live coordinator.
     variants.append(('um, '+text,False,ambiguous,'hesitation'))
     if mode in ('application','web','productivity','dictation'):
      # Repeated narrative is still narrative, not command ambiguity.
      variants.append((text+' '+text,base_more,actionable,'repeated_partial'))
     if mode=='compound':
      headers={
       'train':['Open {app} and','Open {app} and create','Open {app} and create a','Open {app} and create a note called'],
       'calibration':['Start {app}, then','Start {app}, then make','Start {app}, then make a new note named'],
       'test':['Activate {app}; afterwards','Activate {app}; afterwards create','Activate {app}; afterwards create a reminder called']}
      for prefix in headers[split]:variants.append((prefix.format(**entities(split,i)),True,True,'compound_prefix'))
      # A new command after an explicit sentence boundary: no synthetic pause
      # duration is passed to the classifier or claimed as an acoustic sample.
      variants.append((text+'. '+TEMPLATES[split]['application'][0].format(**entities(split,i)),False,ambiguous,'new_command_after_pause'))
     if mode=='correction':
      marker={'train':', no wait','calibration':'; correction','test':'; I mean'}[split]
      variants.append((text+marker,True,True,'partial_correction'))
     for variant_index,(utterance,more,amb,diagnostic) in enumerate(variants):
      key=norm(utterance)
      if key in seen: removals[split]+=1; continue
      seen.add(key)
      rows.append(dict(id=f'{family}/{diagnostic}/{variant_index}',family=family,template_family=f'{split}/{mode}/{ti}',
       split=split,state={'utterance':utterance,'is_final':i%2==0},
       labels={'actionable_command':actionable,'needs_more_speech':more,'correction_or_replacement':mode=='correction',
        'coarse_family':coarse if actionable else None},diagnostic=diagnostic,mode=mode,
       provenance={'source':'controlled synthetic templates plus disjoint scenario entities','human_review':'pending'}))
 # Sample balanced more-speech classes without breaking family assignments.
 selected=[]
 targets={'train':2400,'calibration':400,'test':600}
 for split,total in targets.items():
  rng=random.Random(SEED+len(split))
  for label in (False,True):
   candidates=[r for r in rows if r['split']==split and r['labels']['needs_more_speech']==label]
   # Round-robin semantic/diagnostic slices prevents trailing conjunctions
   # from overwhelming the more-speech head, or positives overwhelming actionability.
   grouped=defaultdict(list)
   for r in candidates:grouped[(r['diagnostic'],r['mode'])].append(r)
   for g in grouped.values():rng.shuffle(g)
   order=list(grouped);rng.shuffle(order);candidates=[]
   while any(grouped.values()):
    for k in order:
     # Training intentionally emphasizes actual app/compound prefix chains.
     # Calibration and held-out retain the same controlled diagnostic mixture.
     weight=3 if split=='train' and label and k[0] in ('streaming_prefix','compound_prefix') else 1
     for _ in range(weight):
      if grouped[k]:candidates.append(grouped[k].pop())
   assert len(candidates)>=total//2,(split,label,len(candidates))
   selected+=candidates[:total//2]
  subset=[r for r in selected if r['split']==split]
  subset.sort(key=lambda r:r['id'])
  (ROOT/f'{split}.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False,sort_keys=True)+'\n' for r in subset))
 audit(selected,removals)
 review=random.Random(SEED).sample(selected,240)
 with (ROOT/'human-review.csv').open('w') as f:
  writer=csv.writer(f);writer.writerow(['id','split','utterance','is_final','actionable_command','needs_more_speech','correction_or_replacement','coarse_family','diagnostic','reviewer','approved','correction'])
  for r in sorted(review,key=lambda r:(r['split'],r['id'])):
   writer.writerow([r['id'],r['split'],r['state']['utterance'],r['state']['is_final'],*r['labels'].values(),r['diagnostic'],'','',''])

def audit(rows,removals):
 counts={}
 for split in TEMPLATES:
  data=[r for r in rows if r['split']==split]
  counts[split]={'count':len(data),'sha256':sha(ROOT/f'{split}.jsonl'),'semantic_scenario_families':len(set(r['family'] for r in data)),
   'template_families':len(set(r['template_family'] for r in data)),
   'balances':{k:dict(Counter(str(r['labels'][k]) for r in data)) for k in data[0]['labels']},
   'diagnostics':dict(Counter(r['diagnostic'] for r in data)), 'prefix_word_lengths':dict(Counter(str(len(r['state']['utterance'].split())) for r in data if r['labels']['needs_more_speech']))}
 assert len(set(r['state']['utterance'] for r in rows))==len(rows)
 assert len(set(r['id'] for r in rows))==len(rows)
 assert len(set(norm(r['state']['utterance']) for r in rows))==len(rows)
 families=defaultdict(set);templates=defaultdict(set)
 for r in rows: families[r['family']].add(r['split']);templates[r['template_family']].add(r['split'])
 assert all(len(v)==1 for v in families.values()) and all(len(v)==1 for v in templates.values())
 literal_templates=[t for modes in TEMPLATES.values() for ts in modes.values() for t in ts]
 assert len(set(literal_templates))==len(literal_templates)
 manifest={'seed':SEED,'splits':counts,'exact_duplicates':0,'normalized_duplicates':0,'scenario_family_overlap':0,'template_family_overlap':0,
  'duplicates_removed_before_freezing':dict(removals),'human_review':'PENDING: 240-example CSV, no independent human review performed',
  'limits':'Synthetic English corpus. Template grammar and target/topic entities (including fixed correction destinations) are disjoint across splits. Shared operation semantics (e.g. launch apps) remain by design; this does not establish natural microphone generalization.',
  'label_policy':{'actionable_command':'Direct current request to act, even if incomplete or unsupported; never an execution grant.',
  'needs_more_speech':'Missing syntactic target/body, unfinished correction/conjunction/sentence. Complete streaming command is negative even with is_final=false.',
  'correction_or_replacement':'Explicit replacement of a requested action, including unfinished correction. Narrative/quoted/hypothetical markers are negative.',
  'coarse_family':'Only labeled on actionable speech; broad topic, never tool or payload.'},'generator_sha256':sha(Path(__file__))}
 (ROOT/'split-manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
 print(json.dumps(counts,indent=2))
if __name__=='__main__':build()
