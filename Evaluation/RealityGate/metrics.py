"""Calibration and selective metrics. Thresholds are fitted on calibration only."""
import math

def accumulation_window(index, count, size):
    if not 0 <= index < count or size < 1:
        raise ValueError("Invalid accumulation window")
    beginning = index // size * size
    return min(size,count-beginning), (index+1)%size==0 or index+1==count

def probabilities(logits, temperature=1.):
    values = [x / temperature for x in logits]
    values = [math.exp(x - max(values)) for x in values]
    return [x / sum(values) for x in values]

def fit_temperature(rows):
    # Deterministic bounded log-space search; no test rows accepted here.
    if any(r["split"] != "calibration" for r in rows):
        raise ValueError("Temperature fitting requires calibration split only")
    best = (float("inf"), 1.)
    for index in range(301):
        t = math.exp(math.log(.1) + index / 300 * math.log(100))
        loss = sum(-math.log(max(probabilities(r["logits"], t)[r["goldIndex"]], 1e-15)) for r in rows) / len(rows)
        best = min(best, (loss, t))
    return best[1]

def wilson_lower(correct, count):
    if not count:
        return None
    z, p = 1.959963984540054, correct / count
    return (p + z*z/(2*count) - z*math.sqrt(p*(1-p)/count + z*z/(4*count*count))) / (1+z*z/count)

def summarize(rows, temperature=1.):
    scored = [(probabilities(r["logits"], temperature), r["goldIndex"]) for r in rows]
    pairs = [(max(p), p.index(max(p)) == gold) for p, gold in scored]
    ece = 0.
    for bucket in range(10):
        selected = [(c, v) for c, v in pairs if bucket / 10 <= c < (bucket+1)/10 or bucket == 9 and c == 1]
        if selected:
            ece += len(selected)/len(pairs) * abs(sum(c for c,_ in selected)/len(selected) - sum(v for _,v in selected)/len(selected))
    result = {"count": len(rows), "accuracy": sum(v for _,v in pairs)/len(pairs), "ece10": ece,
        "nll": sum(-math.log(max(p[g], 1e-15)) for p,g in scored)/len(scored),
        "brier": sum(sum((v-(i==g))**2 for i,v in enumerate(p)) for p,g in scored)/len(scored),
        "confidenceGates": {}}
    for threshold in (.5,.75,.9,.95,.97,.99):
        result["confidenceGates"][str(threshold)] = selective(pairs, threshold)
    if scored and len(scored[0][0]) == 2:
        tp = sum(p[1] > p[0] and g == 1 for p,g in scored)
        predicted = sum(p[1] > p[0] for p,g in scored)
        positive = sum(g == 1 for _,g in scored)
        result.update(precision=tp/predicted if predicted else None, recall=tp/positive if positive else None,
                      positiveCount=positive, predictedPositiveCount=predicted)
    return result

def selective(pairs, threshold):
    selected = [(c, v) for c, v in pairs if c >= threshold] if threshold is not None else []
    count, correct = len(selected), sum(v for _,v in selected)
    return {"threshold": threshold, "accepted": count, "coverage": count/len(pairs),
            "selectiveAccuracy": correct/count if count else None,
            "accuracy95LowerBound": wilson_lower(correct,count)}

def target_coverage(calibration, test, temperature):
    def pairs(rows):
        answer = []
        for row in rows:
            p = probabilities(row["logits"],temperature)
            answer.append((max(p),p.index(max(p))==row["goldIndex"]))
        return answer
    cal, held = pairs(calibration), pairs(test)
    result = {}
    for target in (.95,.97,.99):
        candidates = []
        for threshold in sorted({c for c,_ in cal}):
            s = selective(cal,threshold)
            if s["accepted"] >= 5 and s["selectiveAccuracy"] >= target:
                candidates.append(s)
        empirical = max(candidates, key=lambda x:x["accepted"]) if candidates else None
        supported = [s for s in candidates if s["accuracy95LowerBound"] >= target]
        statistical = max(supported, key=lambda x:x["accepted"]) if supported else None
        result[str(target)] = {"calibrationEmpirical": empirical,
            "testAtCalibrationEmpiricalGate": selective(held,empirical["threshold"] if empirical else None),
            "calibrationStatisticallySupported": statistical,
            "testAtSupportedGate": selective(held,statistical["threshold"] if statistical else None)}
    return result
