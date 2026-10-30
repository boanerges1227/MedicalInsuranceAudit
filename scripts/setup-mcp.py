"""Configure an independent MCP gateway without overwriting existing secrets or printing credentials."""
import json, os, pathlib, secrets, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[1]
private=root/'artifacts'/'mcp-private'
private.mkdir(parents=True,exist_ok=True,mode=0o700);os.chmod(private,0o700)
secret_file=private/'transport.json';config_file=private/'gateway.toml'
if secret_file.exists():
    data=json.loads(secret_file.read_text())
else:
    # If private credentials are missing, do not generate a mismatched password for an existing account; an administrator must restore them.
    check=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','%SYS'],cwd=root,input='write "MCP_USER_EXISTS:",##class(Security.Users).Exists("HDMCPGateway"),!\nhalt\n',text=True,capture_output=True,timeout=30)
    if 'MCP_USER_EXISTS:0' not in check.stdout:
        raise SystemExit('MCP_USER_ALREADY_EXISTS_OR_CHECK_FAILED: restore the private transport configuration')
    data={'password':'Hd9!'+secrets.token_hex(24)}
    fd=os.open(secret_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f:json.dump(data,f)
password=data.get('password','')
if not password.startswith('Hd9!') or len(password)!=52 or any(c not in 'Hd9!0123456789abcdef' for c in password):
    raise SystemExit('INVALID_PRIVATE_CONFIGURATION')
# Pass the password to local IRIS through standard input only; never print echoed commands or secrets.
script='''set status=1
if '##class(Security.Roles).Exists("HDMCPTransport") { set status=##class(Security.Roles).Create("HDMCPTransport","Medical audit MCP transport","%Service_MCPGateway:U","") }
if $system.Status.IsOK(status),'##class(Security.Users).Exists("HDMCPGateway") { set user("Roles")="HDMCPTransport",user("Password")="'''+password+'''",user("Enabled")=1,user("ChangePassword")=0 set status=##class(Security.Users).Create("HDMCPGateway",.user) }
if $system.Status.IsOK(status) { set p("Type")=18,p("NameSpace")="USER",p("DispatchClass")="HD.MCP.Service",p("Enabled")=1,p("AutheEnabled")=64,p("UseCookies")=0,p("MatchRoles")=":%DB_USER",p("Resource")="" if ##class(Security.Applications).Exists("/mcp/medical-audit") { set status=##class(Security.Applications).Modify("/mcp/medical-audit",.p) } else { set status=##class(Security.Applications).Create("/mcp/medical-audit",.p) } }
write "MCP_SETUP_OK:",$system.Status.IsOK(status),!
halt
'''
result=subprocess.run(['docker','compose','exec','-T','iris','iris','session','IRIS','-U','%SYS'],cwd=root,input=script,text=True,capture_output=True,timeout=30)
if 'MCP_SETUP_OK:1' not in result.stdout:raise SystemExit('IRIS_MCP_SETUP_FAILED')
config='''[mcp]
transport = "http"
host = "0.0.0.0"
port = 52875
base_route = "/mcp"
allowed_hosts = ["127.0.0.1", "localhost"]
allowed_origins = ["http://127.0.0.1:52885", "http://localhost:52885"]

[[iris]]
name = "medical"
server = {host="iris",port=1972,username="HDMCPGateway",password="'''+password+'''"}
pool = {min=0,max=1}
endpoints = [{path="/mcp/medical-audit"}]

[logging]
level = "warn"
output = "stderr"
'''
if config_file.exists():
    if config_file.read_text()!=config:raise SystemExit('GATEWAY_CONFIG_CONFLICT')
else:
    fd=os.open(config_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f:f.write(config)
print('MCP_PRIVATE_SETUP_OK')
