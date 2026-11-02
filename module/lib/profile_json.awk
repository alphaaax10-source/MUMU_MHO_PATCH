# Strict scalar-object JSON reader for the flat profile schema.
# Accept arbitrary whitespace, UTF-8 labels, and escaped ASCII/Unicode ASCII.
# Reject duplicate keys, arrays/objects, controls and ambiguous string escapes.
{ input=input $0 "\n" }
function die() { bad=1; exit 2 }
function ws() { while(substr(input,pos,1) ~ /[ \t\r\n]/ && pos<=length(input)) pos++ }
function hex4(s, i,n,c) {
  n=0; for(i=1;i<=4;i++){ c=index("0123456789abcdef",tolower(substr(s,i,1)))-1; if(c<0)die(); n=n*16+c } return n
}
function utf8(n) {
  if(n<128)return sprintf("%c",n)
  if(n<2048)return sprintf("%c%c",192+int(n/64),128+n%64)
  if(n<65536)return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
  return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
}
function quoted(v, out,i,c) {
  out="\""; for(i=1;i<=length(v);i++){c=substr(v,i,1);if(c=="\\"||c=="\"")out=out "\\";out=out c} return out "\""
}
function str(  out,c,e,n,lo) {
  if(substr(input,pos++,1)!="\"")die(); out=""
  while(pos<=length(input)) {
    c=substr(input,pos++,1)
    if(c=="\"")return out
    if(c=="\\") {
      e=substr(input,pos++,1)
      if(e=="u") {
        n=hex4(substr(input,pos,4));pos+=4
        if(n>=55296&&n<=56319){if(substr(input,pos,2)!="\\u")die();pos+=2;lo=hex4(substr(input,pos,4));pos+=4;if(lo<56320||lo>57343)die();n=65536+(n-55296)*1024+lo-56320}
        else if(n>=56320&&n<=57343)die()
        if(n<32||n==127)die();c=utf8(n)
      }
      else if(e=="/")c="/"
      else if(e=="\\"||e=="\"")c=e
      else die()
    }
    if(c ~ /[[:cntrl:]]/)die()
    out=out c
  }
  die()
}
END {
  if(bad)exit 2
  pos=1; ws(); if(substr(input,pos++,1)!="{")die()
  ws(); if(substr(input,pos,1)=="}"){pos++;empty=1}
  while(!empty && pos<=length(input)) {
    ws(); key=str(); if(key !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || key in seen)die(); seen[key]=1
    ws(); if(substr(input,pos++,1)!=":")die(); ws()
    c=substr(input,pos,1)
    if(c=="\"")value=quoted(str())
    else {
      rest=substr(input,pos)
      if(match(rest,/^(true|false|null)/))value=substr(rest,1,RLENGTH)
      else if(match(rest,/^(0|[1-9][0-9]*)/))value=substr(rest,1,RLENGTH)
      else die()
      pos+=length(value)
    }
    lines[++count]="  \"" key "\": " value
    ws(); c=substr(input,pos++,1)
    if(c=="}")break
    if(c!=",")die()
  }
  if(c!="}"&&!empty)die(); ws(); if(pos<=length(input))die()
  print "{"; for(i=1;i<=count;i++)print lines[i] (i<count?",":""); print "}"
}
