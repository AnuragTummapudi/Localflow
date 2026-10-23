"""Fixed-scope manifest-first cleanup. Never git clean; preserve Git/evidence/models.

Run --plan after validation, inspect deletion-manifest.json, then --execute.
No global caches or Apple system assets are candidates.
"""
import argparse, hashlib, json, os, shutil, subprocess
from pathlib import Path
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Evaluation/CoreLock'
SUPPORT = Path.home() / 'Library/Application Support/LocalFlow/Models'
MANIFEST = OUT / 'deletion-manifest.json'

def allocated(p):
    return int(subprocess.check_output(['du', '-sk', str(p)], text=True).split()[0])*1024 if p.exists() else 0

def git_inside(p):
    if p.is_file(): return False
    for base, dirs, files in os.walk(p, followlinks=False):
        if '.git' in dirs or '.git' in files: return True
        if 'HEAD' in files and 'objects' in dirs and 'refs' in dirs: return True
    return False

def snapshot():
    return {'repositoryAllocatedBytes': allocated(ROOT),
            'obsoleteOwnedSpeechAllocatedBytes': sum(allocated(SUPPORT/n) for n in ('parakeet-eou-streaming','parakeet-tdt-0.6b-v3')),
            'filesystemFreeBytes': shutil.disk_usage(ROOT).free}

def candidates():
    rows = []
    def add(path, reason): rows.append((path, reason))
    for name in ('AgentDebug','ReleaseDerivedData','onboarding-derived','xcode-derived'):
        for child in ('Build','CompilationCache.noindex','Index.noindex','Logs','ModuleCache.noindex','SDKStatCaches.noindex'):
            add(ROOT/'.build'/name/child, 'Superseded project-specific Xcode generated products/cache; current unsigned Debug build retained separately.')
        add(ROOT/'.build'/name/'SourcePackages/artifacts', 'Compiled artifacts for obsolete speech dependencies; repository/checkouts/history preserved.')
    for name in ('laya-helper','laya-research/helper-build','core-lock/helper-scratch'):
        for child in ('arm64-apple-macosx','artifacts'):
            add(ROOT/'.build'/name/child, 'Superseded helper products; freshly built macOS 26 helper parity validated and included in retained v2 package.')
    add(ROOT/'.build/arm64-apple-macosx', 'Reproducible SwiftPM products after three final passing regression runs; current Xcode Debug app retained.')
    add(ROOT/'.build/laya-v2/whisper-turbo', 'Obsolete project-owned Whisper speech download; downloader and runtime integration removed, see speech removal audit.')
    add(ROOT/'.build/laya-production-package', 'Duplicate preserved installed v1 model, SHA-256 identical external weights; evidence archived before deletion.')
    for name in ('laya.onnx','laya.onnx.data','laya-inferred.onnx'):
        add(ROOT/'.build/laya-research'/name, 'Obsolete v1 ONNX export/intermediate; weights identical to preserved installed v1, metadata/evaluation preserved.')
    add(ROOT/'.build/reality-gate/quantization-source', 'Obsolete conversion intermediates; external weights identical to preserved installed v1; current v2 package retained.')
    add(ROOT/'dist/LocalFlow.dmg', 'Stale pre-existing release output; no release built or packaged in this task.')
    add(ROOT/'LocalFlow-latest.dmg', 'Pre-existing project release output from September; current architecture requires macOS 26. No release built or packaged in this task; original hash preserved in stale-dmg-proof.json.')
    for name in ('parakeet-eou-streaming','parakeet-tdt-0.6b-v3'):
        add(SUPPORT/name, 'LocalFlow-owned obsolete speech model directory proven by historical ModelManager paths; Apple speech assets and both Laya directories excluded.')
    for parent in ('Evaluation','Runtime','Core'):
        for p in (ROOT/parent).rglob('__pycache__'): add(p, 'Reproducible project Python bytecode cache.')
    for name in ('speech-fixtures','speech-fixtures-broad'):
        for p in (ROOT/'.build/core-lock'/name).rglob('*'):
            if p.suffix in ('.aiff','.caf'): add(p, 'Test-owned synthesized audio; fixture manifest and real Apple result evidence retained.')
    return rows

def plan():
    assert not MANIFEST.exists(), 'Do not overwrite an existing deletion manifest.'
    entries=[];archive=OUT/'ArchivedGeneratedEvidence';archive.mkdir(exist_ok=True)
    for i,(p,reason) in enumerate(candidates()):
        if not p.exists(): continue
        assert not p.is_symlink(), p
        containsGit=git_inside(p)
        files=[p] if p.is_file() else [f for f in p.rglob('*') if f.is_file() and not f.is_symlink()]
        # Preserve evaluation/provenance/config evidence, even inside obsolete products.
        if not containsGit:
            for f in files:
                if f.suffix in ('.json','.jsonl','.md','.py') and f.stat().st_size <= 10_000_000:
                    target=archive/str(i)/(f.name if p.is_file() else f.relative_to(p))
                    target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,target)
        entries.append({'path':str(p),'reason':reason,'allocatedBytes':allocated(p),
                        'logicalBytes':sum(f.stat().st_size for f in files),'containsGit':containsGit,
                        'status':'PRESERVE_GIT' if containsGit else 'PLANNED'})
    for f in (ROOT/'.build/core-lock').glob('*.log'):
        if f.stat().st_size: (OUT/'Logs').mkdir(exist_ok=True);shutil.copy2(f,OUT/'Logs'/f.name)
    fixture=ROOT/'.build/core-lock/speech-fixtures-broad/fixtures.json'
    if fixture.exists():shutil.copy2(fixture,OUT/'apple-fixture-manifest.json')
    value={'createdUTC':datetime.now(timezone.utc).isoformat(),'phase':'PLANNED',
           'scope':'Only fixed project-generated paths and two proven LocalFlow-owned obsolete Parakeet paths. No Git deletion, no git clean, no user data, no global caches, no Apple assets, no Laya checkpoint deletion.',
           'before':snapshot(),'entries':entries}
    MANIFEST.write_text(json.dumps(value,indent=2)+'\n')
    (OUT/'DELETION_MANIFEST.md').write_text('# Generated deletion manifest\n\nCreated before deletion. Full absolute paths, sizes, reasons and outcomes are in deletion-manifest.json. Git-containing candidates are preserved. Current app, v2 models, preserved installed v1, research bases/environments, evaluation evidence and user data are excluded.\n\n'+ '\n'.join(f"- {e['status']}: `{e['path']}` — {e['allocatedBytes']} allocated bytes. {e['reason']}" for e in entries)+'\n')
    print(json.dumps(value['before']));print('planned',sum(e['allocatedBytes'] for e in entries if e['status']=='PLANNED'))

def execute():
    value=json.loads(MANIFEST.read_text());assert value['phase']=='PLANNED'
    allowed={str(p):reason for p,reason in candidates()}
    for entry in value['entries']:
        p=Path(entry['path'])
        assert str(p) in allowed and entry['reason']==allowed[str(p)]
        if entry['status']!='PLANNED':continue
        assert p.exists() and not p.is_symlink() and not git_inside(p), p
        assert allocated(p)==entry['allocatedBytes'], f'Changed since manifest: {p}'
        if p.is_dir():shutil.rmtree(p)
        else:p.unlink()
        entry['status']='DELETED'
        MANIFEST.write_text(json.dumps(value,indent=2)+'\n')
    value['phase']='COMPLETED';value['after']=snapshot();value['completedUTC']=datetime.now(timezone.utc).isoformat()
    MANIFEST.write_text(json.dumps(value,indent=2)+'\n')
    inventory=[]
    for parent in (ROOT/'.build',ROOT/'Models',ROOT/'dist'):
        if parent.exists():
            inventory.append(str(parent.relative_to(ROOT)))
            inventory.extend(str(p.relative_to(ROOT)) for p in parent.rglob('*') if p.is_dir() and not p.is_symlink())
    (OUT/'remaining-generated-directories.txt').write_text('\n'.join(sorted(inventory))+'\n')
    print(json.dumps(value['after']));print('deleted allocated bytes',sum(e['allocatedBytes'] for e in value['entries'] if e['status']=='DELETED'))

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--plan',action='store_true');a.add_argument('--execute',action='store_true');args=a.parse_args()
    assert args.plan != args.execute
    plan() if args.plan else execute()
