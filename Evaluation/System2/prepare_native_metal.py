import hashlib,json,pathlib,subprocess,zipfile
root=pathlib.Path(__file__).resolve().parents[2]
meta=json.loads((root/'Evaluation/System2/native-metal-wheel.json').read_text())
wheel=next(f for f in meta['urls'] if 'arm64.whl' in f['filename'])
artifact=root/'.build/system2'/wheel['filename']
if not artifact.exists() or hashlib.sha256(artifact.read_bytes()).hexdigest()!=wheel['digests']['sha256']:
    subprocess.run(['curl','--fail','--location','--continue-at','-','--retry','4','--retry-all-errors','--silent','--show-error',wheel['url'],'-o',str(artifact)],check=True)
assert hashlib.sha256(artifact.read_bytes()).hexdigest()==wheel['digests']['sha256']
with zipfile.ZipFile(artifact) as z:
    name=next(n for n in z.namelist() if n.endswith('/mlx.metallib'))
    target=root/'.build/system2/swift/release/mlx.metallib';target.write_bytes(z.read(name))
(root/'Evaluation/System2/native-metal-provenance.json').write_text(json.dumps({'version':'0.32.2','url':wheel['url'],'wheelSHA256':wheel['digests']['sha256'],'metallibSHA256':hashlib.sha256(target.read_bytes()).hexdigest(),'metallibBytes':target.stat().st_size,'reason':'Exact MLX core version in mlx-swift 0.32.3; SwiftPM cannot build Metal and this Xcode lacks optional Metal compiler'},indent=2)+'\n')
print('Verified exact native MLX metallib',target.stat().st_size,flush=True)
