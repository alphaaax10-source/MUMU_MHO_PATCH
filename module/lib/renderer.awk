# Exact Name matching (MuMu stores escaped dots). Never interpolate package regexes.
# mode=remove/fields/merge; before/after files preserve proof for one package.
function name(line, v) {
  v=line; sub(/\r$/, "", v)
  if(v !~ /^[ \t]*Name[ \t]+/)return ""
  sub(/^[ \t]*Name[ \t]+/,"",v); sub(/[ \t]+$/, "",v)
  gsub(/\\\./,".",v); return v
}
function key(line) { return line ~ /^[ \t]*CustomizedRendererString([ \t]|\r?$)/ }
function gler_key(line) { return line ~ /^[ \t]*IgnoreGLError([ \t]|\r?$)/ }
function gler_name(v, out, i, c) {
  out=""
  for(i=1; i<=length(v); i++) {
    c=substr(v, i, 1)
    if(c==".") out=out "\\."
    else out=out c
  }
  return out
}

BEGIN {
  if(mode=="merge"){
    while((getline v < field_file)>0) saved[++saved_n]=v
    close(field_file)
    if(saved_n!=1)exit 5
    prev=""; orig_inside=0
    while((getline v < before_file)>0) {
      nm=name(v); if(nm!="")orig_inside=(nm==package)
      if(orig_inside && key(v)) predecessor=prev
      prev=v
    }
    close(before_file)
  }
}
{
  nm=name($0)
  if(nm!="") {
    inside=(nm==package)
    if(inside) { blocks++; anchor=NR }
  }
  text[NR]=$0
  target[NR]=inside
  if(inside && key($0)) { keys++; line_nr=NR; matches++ }
}
END {
  if(blocks>1)exit 3
  if(mode=="fields") {
    if(blocks!=1)exit 4
    for(i=1;i<=NR;i++)if(target[i] && key(text[i]))print text[i]
    if(keys>1)exit 3
  } else if(mode=="remove") {
    if(blocks!=1 || keys!=1 || matches!=1)exit 4
    for(i=1;i<=NR;i++)if(i!=line_nr)print text[i]
  } else if(mode=="merge") {
    if(blocks!=1 || keys!=0 || saved_n!=1)exit 4
    matches=0; location=anchor
    for(i=1;i<=NR;i++)if(target[i] && text[i]==predecessor){matches++;candidate=i}
    if(matches==1)location=candidate
    for(i=1;i<=NR;i++) { print text[i]; if(i==location)print saved[1] }
  } else if(mode=="gler-state") {
    if(blocks==0)exit 4
    found=0
    for(i=1;i<=NR;i++)if(target[i] && gler_key(text[i]))found=1
    if(!found)exit 11
    for(i=1;i<=NR;i++)if(target[i] && gler_key(text[i]))print text[i]
  } else if(mode=="gler-add") {
    if(blocks>1)exit 3
    if(blocks==0) {
      for(i=1;i<=NR;i++)print text[i]
      print "Name " gler_name(package)
      print "IgnoreGLError 1"
      exit 1
    }
    for(i=1;i<=NR;i++)if(target[i] && gler_key(text[i]))exit 10
    for(i=1;i<=NR;i++) {
      print text[i]
      if(i==anchor)print "IgnoreGLError 1"
    }
    exit 0
  } else if(mode=="gler-remove") {
    if(blocks==0)exit 4
    if(blocks>1)exit 3
    found=0; others=0
    for(i=1;i<=NR;i++) {
      if(target[i] && gler_key(text[i]))found=1
      else if(target[i] && name(text[i])=="")others++
    }
    if(!found)exit 10
    drop=0
    if(drop_block && others==0)drop=1
    for(i=1;i<=NR;i++) {
      if(target[i] && gler_key(text[i]))continue
      if(drop && i==anchor)continue
      print text[i]
    }
    exit 0
  } else exit 2
}
