"""Freeze binary/shader hashes and atomically install ONLY this locally built resident helper."""
import pathlib,json,hashlib,shutil,uuid,os
root=pathlib.Path(__file__).resolve().parents[2]
source=root/'.build/system2/swift/release'
assets=[{'name':name,'sha256':hashlib.sha256((source/name).read_bytes()).hexdigest(),'bytes':(source/name).stat().st_size} for name in ['localflow-qwen','mlx.metallib','localflow-workflow-guard']]
manifest=root/'Core/ModelManager/Resources/PlannerRuntime/runtime-manifest.json';manifest.write_text(json.dumps(assets,indent=2)+'\n')
(root/'Features/CommandMode/Resources/workflow-guard.json').write_text(json.dumps(next(a for a in assets if a['name']=='localflow-workflow-guard'),indent=2)+'\n')
target=pathlib.Path.home()/'Library/Application Support/LocalFlow/Models/qwen-runtime';stage=target.parent/('.qwen-runtime-'+str(uuid.uuid4()));stage.mkdir(parents=True,mode=0o700)
for asset in assets:shutil.copy2(source/asset['name'],stage/asset['name'])
# Explicit developer setup owned assets only; an existing helper is retained until the new one is complete.
backup=target.with_name('.qwen-runtime-backup-'+str(uuid.uuid4()))
if target.exists():target.rename(backup)
try:stage.rename(target)
except Exception:
    if backup.exists():backup.rename(target)
    raise
if backup.exists():shutil.rmtree(backup)
(root/'Evaluation/System2/runtime-manifest.json').write_text(manifest.read_text())
print('Pinned native helper prepared; rebuild LocalFlow to trust these exact local artifact hashes.')
