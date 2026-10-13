# Regenerates user_signed.json: python3 user_signed.py > user_signed.json (needs eth_account).
# The keys are throwaway constants (0x11..11 user, 0x22..22 agent) that never held funds.
import json
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak

def payload(primary, types, action):
    return {
        "domain": {"name": "HyperliquidSignTransaction", "version": "1",
                   "chainId": int(action["signatureChainId"], 16),
                   "verifyingContract": "0x0000000000000000000000000000000000000000"},
        "types": {primary: types, "EIP712Domain": [
            {"name": "name", "type": "string"}, {"name": "version", "type": "string"},
            {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}]},
        "primaryType": primary, "message": action}

AGENT = [{"name": "hyperliquidChain", "type": "string"},{"name": "agentAddress", "type": "address"},
         {"name": "agentName", "type": "string"},{"name": "nonce", "type": "uint64"}]
BFEE = [{"name": "hyperliquidChain", "type": "string"},{"name": "maxFeeRate", "type": "string"},
        {"name": "builder", "type": "address"},{"name": "nonce", "type": "uint64"}]
user = Account.from_key("0x" + "11"*32)
agent = Account.from_key("0x" + "22"*32)
out = {"user": user.address.lower(), "agent": agent.address.lower()}
for name, chain_name, aname in [("agent_named","Testnet","copy"),("agent_unnamed","Mainnet","")]:
    action = {"type":"approveAgent","signatureChainId":"0x66eee","hyperliquidChain":chain_name,
              "agentAddress":agent.address,"agentName":aname,"nonce":1700000000000}
    p = payload("HyperliquidTransaction:ApproveAgent", AGENT, action)
    m = encode_typed_data(full_message=p)
    s = user.sign_message(m)
    digest = keccak(b"\x19" + m.version + m.header + m.body)
    if aname == "": del action["agentName"]
    out[name] = {"action": action, "nonce": 1700000000000, "digest": digest.hex(),
                 "signature": {"r": hex(s.r), "s": hex(s.s), "v": s.v}}
action = {"type":"approveBuilderFee","signatureChainId":"0x66eee","hyperliquidChain":"Testnet",
          "maxFeeRate":"0.01%","builder":"0x00000000000000000000000000000000000000bb","nonce":1700000000001}
p = payload("HyperliquidTransaction:ApproveBuilderFee", BFEE, action)
m = encode_typed_data(full_message=p)
s = user.sign_message(m)
out["builder_fee"] = {"action": action, "nonce": 1700000000001,
                      "digest": keccak(b"\x19" + m.version + m.header + m.body).hex(),
                      "signature": {"r": hex(s.r), "s": hex(s.s), "v": s.v}}
print(json.dumps(out, indent=1))
