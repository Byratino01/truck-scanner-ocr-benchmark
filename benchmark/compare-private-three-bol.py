#!/usr/bin/env python3
"""Private 3-BOL address scoring. Never print address values."""
import argparse, json, re
from pathlib import Path

IDS=("BOL_14","BOL_18","BOL_27")
METHODS=("apple_vision","smolvlm","hybrid")
STATES=set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY".split())
def location(value):
    if not isinstance(value,dict): raise ValueError("Location must be an object")
    city=value.get("city")
    state=value.get("state")
    zipcode=value.get("zip")
    if not all(isinstance(v,str) for v in (city,state,zipcode)): raise ValueError("Incomplete location")
    city=" ".join(city.strip().upper().split())
    state=state.strip().upper()
    match=re.fullmatch(r"(\d{5})(?:-\d{4})?",zipcode.strip())
    if not city or state not in STATES or not match: raise ValueError("Invalid location")
    return {"city":city,"state":state,"zip":match.group(1)}
def load(path,methods):
    data=json.loads(Path(path).read_text())
    if not isinstance(data,dict) or set(data)!=set(IDS): raise ValueError("Expected exactly three BOL IDs")
    result={}
    for doc,values in data.items():
        allowed=set(methods) | ({"sha256"} if methods==("verified",) else set())
        if not isinstance(values,dict) or set(values)!=allowed: raise ValueError("Unexpected method or role fields")
        result[doc]={}
        for method,roles in values.items():
            if method=="sha256": continue
            if not isinstance(roles,dict) or set(roles)!={"pickup","delivery"}: raise ValueError("Expected pickup and delivery")
            result[doc][method]={role:location(value) if value is not None else None for role,value in roles.items()}
    return result
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--ground-truth",required=True)
    p.add_argument("--predictions",required=True)
    a=p.parse_args()
    try:
        truth=load(a.ground_truth,("verified",))
        pred=load(a.predictions,METHODS)
    except (ValueError,KeyError,TypeError,FileNotFoundError,json.JSONDecodeError) as e:
        p.error("ACCURACY_NOT_VERIFIED: invalid or missing private ground truth/predictions ("+type(e).__name__+")")
    print("PRIVATE THREE-BOL ACCURACY: 3 documents, 6 address roles; address contents suppressed")
    for method in METHODS:
        counts={field:0 for field in ("city","state","zip","complete")}
        present=0
        for doc in IDS:
            for role in ("pickup","delivery"):
                actual=truth[doc]["verified"][role]
                guess=pred[doc][method][role]
                if actual is None: p.error("Ground truth cannot be unknown")
                if guess is not None:
                    present+=1
                    for field in ("city","state","zip"):
                        counts[field]+=int(guess[field]==actual[field])
                    counts["complete"]+=int(guess==actual)
        print(f"{method}: populated={present}/6 city={counts['city']}/6 state={counts['state']}/6 zip={counts['zip']}/6 complete={counts['complete']}/6")
    print("ACCURACY_VERIFIED: comparison against explicit private ground truth completed")
if __name__=="__main__": main()
