#!/usr/bin/env node
/**
 * Dynamic VM Start Intercept Patch
 *
 * Discovers the VM start function by its semantic signature (the [VM:start]
 * log string and 4-param async function pattern), then injects a Linux
 * bubblewrap session block before the original function body.
 *
 * Version-resilient — discovers identifiers at build time, not hardcoded.
 */
const fs = require('fs');
const path = require('path');

const EXTRACTED_DIR = process.argv[2] || '/tmp/app-extracted';
const INDEX_JS_PATH = path.join(EXTRACTED_DIR, '.vite/build/index.js');

console.log('=== Dynamic Patch: VM Start Intercept ===\n');

let content = fs.readFileSync(INDEX_JS_PATH, 'utf8');

// Discover function signature by matching the stable pattern:
//   async function WORD(WORD,WORD,WORD,WORD){var WORD,...; <arbitrary setup>; WORD.info(`[VM:start]
// The arbitrary-setup window covers version-to-version drift such as the
// condadata.* / operon-* cleanup loops added in v1.6608.x. The capture is
// anchored on the function header + var declarations + first [VM:start] log
// call, which together produce a unique substring suitable for `replace()`.
const sigRegex = /async function (\w+)\((\w+),(\w+),(\w+),(\w+)\)\{(var \w+(?:,\w+)*;.{0,4000}?\w+\.info\(`\[VM:start\])/;
const sigMatch = content.match(sigRegex);

if (!sigMatch) {
  console.error('  ERROR: Could not find VM start function via [VM:start] pattern');
  process.exit(1);
}

const funcName = sigMatch[1];
const params = [sigMatch[2], sigMatch[3], sigMatch[4], sigMatch[5]];
const originalBody = sigMatch[6];

console.log(`  Found VM start function: ${funcName}(${params.join(',')})`);

// Discover status dispatch: WORD(WORD.Ready) near VM startup code
// Look for patterns like YF(Yw.Ready) or similar near [Heartbeat] or lam_vm_startup
const statusRegex1 = /([\w$]+)\(([\w$]+)\.Ready\),[\w$]+\("lam_vm_startup_completed"/;
const statusRegex2 = /([\w$]+)\(([\w$]+)\.Ready\).{0,100}\[Heartbeat\]/;
const statusMatch = content.match(statusRegex1) || content.match(statusRegex2);

let statusDispatch = 'console.log("[Cowork Linux] Ready")';
if (statusMatch) {
  statusDispatch = `${statusMatch[1]}(${statusMatch[2]}.Ready)`;
  console.log(`  Found status dispatch: ${statusDispatch}`);
} else {
  console.log('  WARNING: Could not find status dispatch, using console.log fallback');
}

// Build the injection block
const injection = `async function ${funcName}(${params.join(',')}){
  if(process.platform==="linux"&&global.__linuxCowork&&!global.__linuxCowork.vmInstance){
    console.log("[Cowork Linux] Creating session");
    const {manager}=global.__linuxCowork;
    try {
      // Use stable sessionId so session data persists across app restarts
      const _fs0=require("fs"),_path0=require("path"),_crypto0=require("crypto");
      const _markerDir=_path0.join(process.env.HOME||"/tmp",".config","Claude","cowork-linux");
      _fs0.mkdirSync(_markerDir,{recursive:true});
      const _markerFile=_path0.join(_markerDir,"session-id");
      let sessionId;
      try{sessionId=_fs0.readFileSync(_markerFile,"utf8").trim()}catch(e){sessionId=_crypto0.randomUUID();_fs0.writeFileSync(_markerFile,sessionId)}
      manager.createSession(sessionId);
      console.log("[Cowork Linux] Session:",sessionId);
      const _procs=new Map();
      const _sessionBase=require("path").join("/tmp/claude-cowork-sessions",sessionId);
      const _resolvePath=(p)=>{if(typeof p==="string"&&p.startsWith("/sessions/")){const parts=p.split("/");const name=parts[2];return require("path").join(_sessionBase,"sessions",name,...parts.slice(3))}return p};
      const vmInstance={
        sessionId,
        isConnected:()=>true,
        isGuestConnected:()=>Promise.resolve(true),
        isProcessRunning:(id)=>{if(id==="__heartbeat_ping__")return Promise.resolve(true);const p=_procs.get(id);return Promise.resolve(p?!p.killed:false)},
        startVM:async()=>{},
        stopVM:async()=>{},
        installSdk:async()=>{},
        setEventCallbacks:(onStdout,onStderr,onExit,onError)=>{global.__linuxCowork._eventCbs={onStdout,onStderr,onExit,onError}},
        executeCommand:(cmd)=>manager.spawnSandboxed(sessionId,cmd.command,cmd.args||[]),
        addMount:(hostPath)=>manager.addMount(sessionId,hostPath),
        dispose:()=>{_procs.forEach((p)=>{try{p.kill()}catch(e){}});_procs.clear();manager.destroySession(sessionId);delete global.__linuxCowork.vmInstance},
        addApprovedOauthToken:()=>Promise.resolve(),
        writeStdin:async(id,data)=>{const p=_procs.get(id);if(p&&p.stdin&&!p.stdin.destroyed){let d=typeof data==="string"?data:data.toString();if(!d.endsWith("\\n"))d+="\\n";p.stdin.write(d)}},
        kill:async(id,signal)=>{const p=_procs.get(id);if(p){p.kill(signal||"SIGTERM")}},
        spawn:(id,name,command,args,cwd,env,additionalMounts,isResume,allowedDomains,oneShot)=>{
          console.log("[Cowork Linux] spawn:",id,name,command,"cwd=",cwd,"mounts=",additionalMounts?Object.keys(additionalMounts):"none");
          let resolvedCmd=command;
          if(command==="/usr/local/bin/claude"||command==="claude"){
            const tryPaths=[process.env.HOME+"/.local/bin/claude","/etc/profiles/per-user/"+process.env.USER+"/bin/claude","/usr/local/bin/claude"];
            const found=tryPaths.find(p=>require("fs").existsSync(p));
            if(found){resolvedCmd=found;console.log("[Cowork Linux] Resolved claude ->",found)}
            else{console.error("[Cowork Linux] claude binary not found in:",tryPaths)}
          }
          const _fs=require("fs"),_path=require("path");
          // Create session directory structure
          let sessionDir=_path.join(_sessionBase,"sessions",name);
          // Create /tmp/sessions/<name> -> sessionDir symlink for Bash tool compatibility
          // Claude Code generates /sessions/<name>/mnt/... paths (VM-internal)
          // FHS variant binds /tmp/sessions -> /sessions, making them accessible
          const _tmpSessions="/tmp/sessions";
          _fs.mkdirSync(_tmpSessions,{recursive:true});
          const _tmpLink=_path.join(_tmpSessions,name);
          try{if(!_fs.existsSync(_tmpLink))_fs.symlinkSync(sessionDir,_tmpLink)}catch(e){}
          _fs.mkdirSync(sessionDir,{recursive:true});
          // Set up mnt/ with symlinks from additionalMounts
          const mntDir=_path.join(sessionDir,"mnt");
          _fs.mkdirSync(mntDir,{recursive:true});
          if(additionalMounts&&typeof additionalMounts==="object"){
            // Sort by depth so parent mounts are created before children
            const sortedMounts=Object.entries(additionalMounts).sort((a,b)=>a[0].split("/").length-b[0].split("/").length);
            const createdMounts=new Set();
            for(const [mountName,mountInfo] of sortedMounts){
              const mountPoint=_path.join(mntDir,mountName);
              const hostPath=mountInfo&&mountInfo.path?mountInfo.path:null;
              // Skip if a parent mount already covers this path (e.g., .claude/skills inside .claude)
              const isNested=[...createdMounts].some(m=>mountName.startsWith(m+"/"));
              if(isNested){console.log("[Cowork Linux] mount:",mountName,"(nested, skipped)");continue}
              if(hostPath&&!_fs.existsSync(mountPoint)){
                const resolvedHost=hostPath.startsWith("/")?hostPath:"/"+hostPath;
                try{_fs.mkdirSync(_path.dirname(mountPoint),{recursive:true});_fs.symlinkSync(resolvedHost,mountPoint);createdMounts.add(mountName);console.log("[Cowork Linux] mount:",mountName,"->",resolvedHost)}
                catch(e){console.warn("[Cowork Linux] mount symlink failed:",mountName,e.message);_fs.mkdirSync(mountPoint,{recursive:true})}
              }else if(!_fs.existsSync(mountPoint)){_fs.mkdirSync(mountPoint,{recursive:true})}
            }
          }
          // Resolve cwd: use session dir (which has mnt/ structure)
          let resolvedCwd=sessionDir;
          if(typeof cwd==="string"&&!cwd.startsWith("/sessions/")&&_fs.existsSync(cwd)){
            resolvedCwd=cwd;
          }
          console.log("[Cowork Linux] cwd ->",resolvedCwd);
          const {spawn:_spawn}=require("child_process");
          const mergedEnv={...process.env,...(env&&typeof env==="object"?env:{})};
          // Fix CLAUDE_CONFIG_DIR: use host path from additionalMounts if available
          if(mergedEnv.CLAUDE_CONFIG_DIR&&mergedEnv.CLAUDE_CONFIG_DIR.startsWith("/sessions/")){
            let hostConfigDir=null;
            if(additionalMounts&&additionalMounts[".claude"]&&additionalMounts[".claude"].path){
              hostConfigDir=additionalMounts[".claude"].path;
              // The path from additionalMounts might be in VM subpath format (no leading /)
              if(!hostConfigDir.startsWith("/"))hostConfigDir="/"+hostConfigDir;
            }
            if(!hostConfigDir||!_fs.existsSync(_path.dirname(hostConfigDir))){
              hostConfigDir=_path.join(sessionDir,"mnt",".claude");
            }
            _fs.mkdirSync(hostConfigDir,{recursive:true});
            mergedEnv.CLAUDE_CONFIG_DIR=hostConfigDir;
            console.log("[Cowork Linux] CLAUDE_CONFIG_DIR ->",hostConfigDir);
          }
          // Remove empty ANTHROPIC_API_KEY (OAuth token is used instead)
          if(mergedEnv.ANTHROPIC_API_KEY==="")delete mergedEnv.ANTHROPIC_API_KEY;
          const child=_spawn(resolvedCmd,args||[],{stdio:["pipe","pipe","pipe"],cwd:resolvedCwd,env:mergedEnv});
          _procs.set(id,child);
          const cbs=global.__linuxCowork._eventCbs||{};
          if(child.stdout)child.stdout.on("data",(d)=>{if(cbs.onStdout)cbs.onStdout(id,d.toString())});
          if(child.stderr)child.stderr.on("data",(d)=>{if(cbs.onStderr)cbs.onStderr(id,d.toString())});
          child.on("exit",(code,sig)=>{_procs.delete(id);if(cbs.onExit)cbs.onExit(id,code,sig)});
          child.on("error",(e)=>{console.error("[Cowork Linux] spawn error id="+id+":",e.message);if(cbs.onError)cbs.onError(id,e.message,true)});
          // v1.13576.4's caller destructures failedMounts from the spawn result, then
          // calls confirmSpawn(failedMounts). Return an empty list (Linux uses symlink
          // mounts, which always resolve) so destructuring succeeds and spawn is confirmed.
          return{failedMounts:[]};
        },
        exec:(command)=>manager.spawnSandboxed(sessionId,'/bin/sh',['-c',command]),
        mkdir:(p)=>{require("fs").mkdirSync(_resolvePath(p),{recursive:true});return Promise.resolve()},
        readFile:(p,enc)=>Promise.resolve(require('fs').readFileSync(_resolvePath(p),enc||'utf8')),
        writeFile:(p,data,enc)=>{require('fs').writeFileSync(_resolvePath(p),data,enc||'utf8');return Promise.resolve()},
        rm:(p)=>{try{require("fs").rmSync(_resolvePath(p),{recursive:true,force:true})}catch(e){};return Promise.resolve()},
        configure:async()=>{},
        createVM:async()=>{},
        mountPath:async(processId,subpath,mountName,mode)=>{const _fs=require("fs"),_path=require("path");const mntDir=_path.join(_sessionBase,subpath,mountName);if(!_fs.existsSync(mntDir)){_fs.mkdirSync(_path.dirname(mntDir),{recursive:true});
          // Check if this is a user folder mount - subpath contains the vmProcessName
          // The desktop app will call mountPath after the user picks a directory
          // hostPath info comes through the mount registry, not this call
          _fs.mkdirSync(mntDir,{recursive:true})};console.log("[Cowork Linux] mountPath:",mountName,"at",mntDir,"mode:",mode)},
        getVmProcessId:()=>'cowork-linux-'+sessionId.slice(0,8),
        connect:async()=>{},
        disconnect:async()=>{_procs.forEach((p)=>{try{p.kill()}catch(e){}});_procs.clear();manager.destroySession(sessionId)},
      };
      global.__linuxCowork.vmInstance=vmInstance;
      try{${statusDispatch}}catch(e){console.log("[Cowork Linux] Status dispatch note:",e.message)}
      console.log("[Cowork Linux] VM instance ready");
      return vmInstance;
    }catch(e){console.error("[Cowork Linux] Session creation failed:",e)}
  }
  ${originalBody}`;

// Find and replace the original function start
const originalStart = `async function ${funcName}(${params.join(',')}){${originalBody}`;

if (!content.includes(originalStart)) {
  console.error('  ERROR: Could not locate original function for replacement');
  process.exit(1);
}

content = content.replace(originalStart, injection);
fs.writeFileSync(INDEX_JS_PATH, content);

// Verify
const patched = fs.readFileSync(INDEX_JS_PATH, 'utf8');
if (!patched.includes('global.__linuxCowork.vmInstance=vmInstance')) {
  console.error('  ERROR: Verification failed — injection not found in output');
  process.exit(1);
}

console.log('  VM start intercept applied successfully\n');
