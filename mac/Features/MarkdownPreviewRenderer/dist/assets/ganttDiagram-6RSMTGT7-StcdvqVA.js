import{g as xe,s as Te,q as be,p as we,a as _e,b as De,_ as c,c as ut,d as vt,e as Se,H as X,l as nt,k as Ce,j as Me,y as Ee,u as Ie}from"./mermaid.core-B8ruo8LJ.js";import{g as It}from"./index-BRLuEQ49.js";import{G as Ye,m as $e,a as Fe,i as Ae,D as Zt,z as Qt,y as Le,I as Oe,J as We,K as Pe,L as Ve,M as ze,x as Re,w as Kt,v as Jt,t as te,s as ee,q as re}from"./time--neCDRwU.js";import{L as Ne}from"./linear-CkvVQetc.js";import"./step-CWYRs_IJ.js";import"./init-Dmth1JHB.js";import"./defaultLocale-D_bw6QrF.js";function He(t){return t}var Tt=1,$t=2,At=3,xt=4,se=1e-6;function Be(t){return"translate("+t+",0)"}function qe(t){return"translate(0,"+t+")"}function Ge(t){return r=>+t(r)}function Xe(t,r){return r=Math.max(0,t.bandwidth()-r*2)/2,t.round()&&(r=Math.round(r)),n=>+t(n)+r}function je(){return!this.__axis}function de(t,r){var n=[],i=null,a=null,m=6,h=6,T=3,M=typeof window<"u"&&window.devicePixelRatio>1?0:.5,$=t===Tt||t===xt?-1:1,b=t===xt||t===$t?"x":"y",L=t===Tt||t===At?Be:qe;function C(D){var R=i??(r.ticks?r.ticks.apply(r,n):r.domain()),I=a??(r.tickFormat?r.tickFormat.apply(r,n):He),S=Math.max(m,0)+T,E=r.range(),W=+E[0]+M,A=+E[E.length-1]+M,N=(r.bandwidth?Xe:Ge)(r.copy(),M),H=D.selection?D.selection():D,Y=H.selectAll(".domain").data([null]),p=H.selectAll(".tick").data(R,r).order(),d=p.exit(),u=p.enter().append("g").attr("class","tick"),x=p.select("line"),v=p.select("text");Y=Y.merge(Y.enter().insert("path",".tick").attr("class","domain").attr("stroke","currentColor")),p=p.merge(u),x=x.merge(u.append("line").attr("stroke","currentColor").attr(b+"2",$*m)),v=v.merge(u.append("text").attr("fill","currentColor").attr(b,$*S).attr("dy",t===Tt?"0em":t===At?"0.71em":"0.32em")),D!==H&&(Y=Y.transition(D),p=p.transition(D),x=x.transition(D),v=v.transition(D),d=d.transition(D).attr("opacity",se).attr("transform",function(k){return isFinite(k=N(k))?L(k+M):this.getAttribute("transform")}),u.attr("opacity",se).attr("transform",function(k){var f=this.parentNode.__axis;return L((f&&isFinite(f=f(k))?f:N(k))+M)})),d.remove(),Y.attr("d",t===xt||t===$t?h?"M"+$*h+","+W+"H"+M+"V"+A+"H"+$*h:"M"+M+","+W+"V"+A:h?"M"+W+","+$*h+"V"+M+"H"+A+"V"+$*h:"M"+W+","+M+"H"+A),p.attr("opacity",1).attr("transform",function(k){return L(N(k)+M)}),x.attr(b+"2",$*m),v.attr(b,$*S).text(I),H.filter(je).attr("fill","none").attr("font-size",10).attr("font-family","sans-serif").attr("text-anchor",t===$t?"start":t===xt?"end":"middle"),H.each(function(){this.__axis=N})}return C.scale=function(D){return arguments.length?(r=D,C):r},C.ticks=function(){return n=Array.from(arguments),C},C.tickArguments=function(D){return arguments.length?(n=D==null?[]:Array.from(D),C):n.slice()},C.tickValues=function(D){return arguments.length?(i=D==null?null:Array.from(D),C):i&&i.slice()},C.tickFormat=function(D){return arguments.length?(a=D,C):a},C.tickSize=function(D){return arguments.length?(m=h=+D,C):m},C.tickSizeInner=function(D){return arguments.length?(m=+D,C):m},C.tickSizeOuter=function(D){return arguments.length?(h=+D,C):h},C.tickPadding=function(D){return arguments.length?(T=+D,C):T},C.offset=function(D){return arguments.length?(M=+D,C):M},C}function Ue(t){return de(Tt,t)}function Ze(t){return de(At,t)}var bt={exports:{}},Qe=bt.exports,ie;function Ke(){return ie||(ie=1,(function(t,r){(function(n,i){t.exports=i()})(Qe,(function(){var n="day";return function(i,a,m){var h=function($){return $.add(4-$.isoWeekday(),n)},T=a.prototype;T.isoWeekYear=function(){return h(this).year()},T.isoWeek=function($){if(!this.$utils().u($))return this.add(7*($-this.isoWeek()),n);var b,L,C,D,R=h(this),I=(b=this.isoWeekYear(),L=this.$u,C=(L?m.utc:m)().year(b).startOf("year"),D=4-C.isoWeekday(),C.isoWeekday()>4&&(D+=7),C.add(D,n));return R.diff(I,"week")+1},T.isoWeekday=function($){return this.$utils().u($)?this.day()||7:this.day(this.day()%7?$:$-7)};var M=T.startOf;T.startOf=function($,b){var L=this.$utils(),C=!!L.u(b)||b;return L.p($)==="isoweek"?C?this.date(this.date()-(this.isoWeekday()-1)).startOf("day"):this.date(this.date()-1-(this.isoWeekday()-1)+7).endOf("day"):M.bind(this)($,b)}}}))})(bt)),bt.exports}var Je=Ke();const tr=It(Je);var wt={exports:{}},er=wt.exports,ne;function rr(){return ne||(ne=1,(function(t,r){(function(n,i){t.exports=i()})(er,(function(){var n={LTS:"h:mm:ss A",LT:"h:mm A",L:"MM/DD/YYYY",LL:"MMMM D, YYYY",LLL:"MMMM D, YYYY h:mm A",LLLL:"dddd, MMMM D, YYYY h:mm A"},i=/(\[[^[]*\])|([-_:/.,()\s]+)|(A|a|Q|YYYY|YY?|ww?|MM?M?M?|Do|DD?|hh?|HH?|mm?|ss?|S{1,3}|z|ZZ?)/g,a=/\d/,m=/\d\d/,h=/\d\d?/,T=/\d*[^-_:/,()\s\d]+/,M={},$=function(S){return(S=+S)+(S>68?1900:2e3)},b=function(S){return function(E){this[S]=+E}},L=[/[+-]\d\d:?(\d\d)?|Z/,function(S){(this.zone||(this.zone={})).offset=(function(E){if(!E||E==="Z")return 0;var W=E.match(/([+-]|\d\d)/g),A=60*W[1]+(+W[2]||0);return A===0?0:W[0]==="+"?-A:A})(S)}],C=function(S){var E=M[S];return E&&(E.indexOf?E:E.s.concat(E.f))},D=function(S,E){var W,A=M.meridiem;if(A){for(var N=1;N<=24;N+=1)if(S.indexOf(A(N,0,E))>-1){W=N>12;break}}else W=S===(E?"pm":"PM");return W},R={A:[T,function(S){this.afternoon=D(S,!1)}],a:[T,function(S){this.afternoon=D(S,!0)}],Q:[a,function(S){this.month=3*(S-1)+1}],S:[a,function(S){this.milliseconds=100*+S}],SS:[m,function(S){this.milliseconds=10*+S}],SSS:[/\d{3}/,function(S){this.milliseconds=+S}],s:[h,b("seconds")],ss:[h,b("seconds")],m:[h,b("minutes")],mm:[h,b("minutes")],H:[h,b("hours")],h:[h,b("hours")],HH:[h,b("hours")],hh:[h,b("hours")],D:[h,b("day")],DD:[m,b("day")],Do:[T,function(S){var E=M.ordinal,W=S.match(/\d+/);if(this.day=W[0],E)for(var A=1;A<=31;A+=1)E(A).replace(/\[|\]/g,"")===S&&(this.day=A)}],w:[h,b("week")],ww:[m,b("week")],M:[h,b("month")],MM:[m,b("month")],MMM:[T,function(S){var E=C("months"),W=(C("monthsShort")||E.map((function(A){return A.slice(0,3)}))).indexOf(S)+1;if(W<1)throw new Error;this.month=W%12||W}],MMMM:[T,function(S){var E=C("months").indexOf(S)+1;if(E<1)throw new Error;this.month=E%12||E}],Y:[/[+-]?\d+/,b("year")],YY:[m,function(S){this.year=$(S)}],YYYY:[/\d{4}/,b("year")],Z:L,ZZ:L};function I(S){var E,W;E=S,W=M&&M.formats;for(var A=(S=E.replace(/(\[[^\]]+])|(LTS?|l{1,4}|L{1,4})/g,(function(x,v,k){var f=k&&k.toUpperCase();return v||W[k]||n[k]||W[f].replace(/(\[[^\]]+])|(MMMM|MM|DD|dddd)/g,(function(o,l,y){return l||y.slice(1)}))}))).match(i),N=A.length,H=0;H<N;H+=1){var Y=A[H],p=R[Y],d=p&&p[0],u=p&&p[1];A[H]=u?{regex:d,parser:u}:Y.replace(/^\[|\]$/g,"")}return function(x){for(var v={},k=0,f=0;k<N;k+=1){var o=A[k];if(typeof o=="string")f+=o.length;else{var l=o.regex,y=o.parser,g=x.slice(f),w=l.exec(g)[0];y.call(v,w),x=x.replace(w,"")}}return(function(s){var z=s.afternoon;if(z!==void 0){var e=s.hours;z?e<12&&(s.hours+=12):e===12&&(s.hours=0),delete s.afternoon}})(v),v}}return function(S,E,W){W.p.customParseFormat=!0,S&&S.parseTwoDigitYear&&($=S.parseTwoDigitYear);var A=E.prototype,N=A.parse;A.parse=function(H){var Y=H.date,p=H.utc,d=H.args;this.$u=p;var u=d[1];if(typeof u=="string"){var x=d[2]===!0,v=d[3]===!0,k=x||v,f=d[2];v&&(f=d[2]),M=this.$locale(),!x&&f&&(M=W.Ls[f]),this.$d=(function(g,w,s,z){try{if(["x","X"].indexOf(w)>-1)return new Date((w==="X"?1e3:1)*g);var e=I(w)(g),_=e.year,V=e.month,P=e.day,O=e.hours,G=e.minutes,F=e.seconds,Q=e.milliseconds,rt=e.zone,ot=e.week,ht=new Date,mt=P||(_||V?1:ht.getDate()),ct=_||ht.getFullYear(),B=0;_&&!V||(B=V>0?V-1:ht.getMonth());var Z,j=O||0,it=G||0,K=F||0,st=Q||0;return rt?new Date(Date.UTC(ct,B,mt,j,it,K,st+60*rt.offset*1e3)):s?new Date(Date.UTC(ct,B,mt,j,it,K,st)):(Z=new Date(ct,B,mt,j,it,K,st),ot&&(Z=z(Z).week(ot).toDate()),Z)}catch{return new Date("")}})(Y,u,p,W),this.init(),f&&f!==!0&&(this.$L=this.locale(f).$L),k&&Y!=this.format(u)&&(this.$d=new Date("")),M={}}else if(u instanceof Array)for(var o=u.length,l=1;l<=o;l+=1){d[1]=u[l-1];var y=W.apply(this,d);if(y.isValid()){this.$d=y.$d,this.$L=y.$L,this.init();break}l===o&&(this.$d=new Date(""))}else N.call(this,H)}}}))})(wt)),wt.exports}var sr=rr();const ir=It(sr);var _t={exports:{}},nr=_t.exports,ae;function ar(){return ae||(ae=1,(function(t,r){(function(n,i){t.exports=i()})(nr,(function(){return function(n,i){var a=i.prototype,m=a.format;a.format=function(h){var T=this,M=this.$locale();if(!this.isValid())return m.bind(this)(h);var $=this.$utils(),b=(h||"YYYY-MM-DDTHH:mm:ssZ").replace(/\[([^\]]+)]|Q|wo|ww|w|WW|W|zzz|z|gggg|GGGG|Do|X|x|k{1,2}|S/g,(function(L){switch(L){case"Q":return Math.ceil((T.$M+1)/3);case"Do":return M.ordinal(T.$D);case"gggg":return T.weekYear();case"GGGG":return T.isoWeekYear();case"wo":return M.ordinal(T.week(),"W");case"w":case"ww":return $.s(T.week(),L==="w"?1:2,"0");case"W":case"WW":return $.s(T.isoWeek(),L==="W"?1:2,"0");case"k":case"kk":return $.s(String(T.$H===0?24:T.$H),L==="k"?1:2,"0");case"X":return Math.floor(T.$d.getTime()/1e3);case"x":return T.$d.getTime();case"z":return"["+T.offsetName()+"]";case"zzz":return"["+T.offsetName("long")+"]";default:return L}}));return m.bind(this)(b)}}}))})(_t)),_t.exports}var or=ar();const cr=It(or);var Dt={exports:{}},lr=Dt.exports,oe;function ur(){return oe||(oe=1,(function(t,r){(function(n,i){t.exports=i()})(lr,(function(){var n,i,a=1e3,m=6e4,h=36e5,T=864e5,M=31536e6,$=2628e6,b=/^(-|\+)?P(?:([-+]?[0-9,.]*)Y)?(?:([-+]?[0-9,.]*)M)?(?:([-+]?[0-9,.]*)W)?(?:([-+]?[0-9,.]*)D)?(?:T(?:([-+]?[0-9,.]*)H)?(?:([-+]?[0-9,.]*)M)?(?:([-+]?[0-9,.]*)S)?)?$/,L=/\[([^\]]+)]|YYYY|YY|Y|M{1,2}|D{1,2}|H{1,2}|m{1,2}|s{1,2}|SSS/g,C={years:M,months:$,days:T,hours:h,minutes:m,seconds:a,milliseconds:1,weeks:6048e5},D=function(Y){return Y instanceof N},R=function(Y,p,d){return new N(Y,d,p.$l)},I=function(Y){return i.p(Y)+"s"},S=function(Y){return Y<0},E=function(Y){return S(Y)?Math.ceil(Y):Math.floor(Y)},W=function(Y){return Math.abs(Y)},A=function(Y,p){return Y?S(Y)?{negative:!0,format:""+W(Y)+p}:{negative:!1,format:""+Y+p}:{negative:!1,format:""}},N=(function(){function Y(d,u,x){var v=this;if(this.$d={},this.$l=x,d===void 0&&(this.$ms=0,this.parseFromMilliseconds()),u)return R(d*C[I(u)],this);if(typeof d=="number")return this.$ms=d,this.parseFromMilliseconds(),this;if(typeof d=="object")return Object.keys(d).forEach((function(o){v.$d[I(o)]=d[o]})),this.calMilliseconds(),this;if(typeof d=="string"){var k=d.match(b);if(k){var f=k.slice(2).map((function(o){return o!=null?Number(o):0}));return this.$d.years=f[0],this.$d.months=f[1],this.$d.weeks=f[2],this.$d.days=f[3],this.$d.hours=f[4],this.$d.minutes=f[5],this.$d.seconds=f[6],this.calMilliseconds(),this}}return this}var p=Y.prototype;return p.calMilliseconds=function(){var d=this;this.$ms=Object.keys(this.$d).reduce((function(u,x){return u+(d.$d[x]||0)*C[x]}),0)},p.parseFromMilliseconds=function(){var d=this.$ms;this.$d.years=E(d/M),d%=M,this.$d.months=E(d/$),d%=$,this.$d.days=E(d/T),d%=T,this.$d.hours=E(d/h),d%=h,this.$d.minutes=E(d/m),d%=m,this.$d.seconds=E(d/a),d%=a,this.$d.milliseconds=d},p.toISOString=function(){var d=A(this.$d.years,"Y"),u=A(this.$d.months,"M"),x=+this.$d.days||0;this.$d.weeks&&(x+=7*this.$d.weeks);var v=A(x,"D"),k=A(this.$d.hours,"H"),f=A(this.$d.minutes,"M"),o=this.$d.seconds||0;this.$d.milliseconds&&(o+=this.$d.milliseconds/1e3,o=Math.round(1e3*o)/1e3);var l=A(o,"S"),y=d.negative||u.negative||v.negative||k.negative||f.negative||l.negative,g=k.format||f.format||l.format?"T":"",w=(y?"-":"")+"P"+d.format+u.format+v.format+g+k.format+f.format+l.format;return w==="P"||w==="-P"?"P0D":w},p.toJSON=function(){return this.toISOString()},p.format=function(d){var u=d||"YYYY-MM-DDTHH:mm:ss",x={Y:this.$d.years,YY:i.s(this.$d.years,2,"0"),YYYY:i.s(this.$d.years,4,"0"),M:this.$d.months,MM:i.s(this.$d.months,2,"0"),D:this.$d.days,DD:i.s(this.$d.days,2,"0"),H:this.$d.hours,HH:i.s(this.$d.hours,2,"0"),m:this.$d.minutes,mm:i.s(this.$d.minutes,2,"0"),s:this.$d.seconds,ss:i.s(this.$d.seconds,2,"0"),SSS:i.s(this.$d.milliseconds,3,"0")};return u.replace(L,(function(v,k){return k||String(x[v])}))},p.as=function(d){return this.$ms/C[I(d)]},p.get=function(d){var u=this.$ms,x=I(d);return x==="milliseconds"?u%=1e3:u=x==="weeks"?E(u/C[x]):this.$d[x],u||0},p.add=function(d,u,x){var v;return v=u?d*C[I(u)]:D(d)?d.$ms:R(d,this).$ms,R(this.$ms+v*(x?-1:1),this)},p.subtract=function(d,u){return this.add(d,u,!0)},p.locale=function(d){var u=this.clone();return u.$l=d,u},p.clone=function(){return R(this.$ms,this)},p.humanize=function(d){return n().add(this.$ms,"ms").locale(this.$l).fromNow(!d)},p.valueOf=function(){return this.asMilliseconds()},p.milliseconds=function(){return this.get("milliseconds")},p.asMilliseconds=function(){return this.as("milliseconds")},p.seconds=function(){return this.get("seconds")},p.asSeconds=function(){return this.as("seconds")},p.minutes=function(){return this.get("minutes")},p.asMinutes=function(){return this.as("minutes")},p.hours=function(){return this.get("hours")},p.asHours=function(){return this.as("hours")},p.days=function(){return this.get("days")},p.asDays=function(){return this.as("days")},p.weeks=function(){return this.get("weeks")},p.asWeeks=function(){return this.as("weeks")},p.months=function(){return this.get("months")},p.asMonths=function(){return this.as("months")},p.years=function(){return this.get("years")},p.asYears=function(){return this.as("years")},Y})(),H=function(Y,p,d){return Y.add(p.years()*d,"y").add(p.months()*d,"M").add(p.days()*d,"d").add(p.hours()*d,"h").add(p.minutes()*d,"m").add(p.seconds()*d,"s").add(p.milliseconds()*d,"ms")};return function(Y,p,d){n=d,i=d().$utils(),d.duration=function(v,k){var f=d.locale();return R(v,{$l:f},k)},d.isDuration=D;var u=p.prototype.add,x=p.prototype.subtract;p.prototype.add=function(v,k){return D(v)?H(this,v,1):u.bind(this)(v,k)},p.prototype.subtract=function(v,k){return D(v)?H(this,v,-1):x.bind(this)(v,k)}}}))})(Dt)),Dt.exports}var dr=ur();const fr=It(dr);var Lt=(function(){var t=c(function(f,o,l,y){for(l=l||{},y=f.length;y--;l[f[y]]=o);return l},"o"),r=[6,8,10,12,13,14,15,16,17,18,20,21,22,23,24,25,26,27,28,29,30,31,33,35,36,38,40],n=[1,26],i=[1,27],a=[1,28],m=[1,29],h=[1,30],T=[1,31],M=[1,32],$=[1,33],b=[1,34],L=[1,9],C=[1,10],D=[1,11],R=[1,12],I=[1,13],S=[1,14],E=[1,15],W=[1,16],A=[1,19],N=[1,20],H=[1,21],Y=[1,22],p=[1,23],d=[1,25],u=[1,35],x={trace:c(function(){},"trace"),yy:{},symbols_:{error:2,start:3,gantt:4,document:5,EOF:6,line:7,SPACE:8,statement:9,NL:10,weekday:11,weekday_monday:12,weekday_tuesday:13,weekday_wednesday:14,weekday_thursday:15,weekday_friday:16,weekday_saturday:17,weekday_sunday:18,weekend:19,weekend_friday:20,weekend_saturday:21,dateFormat:22,inclusiveEndDates:23,topAxis:24,axisFormat:25,tickInterval:26,excludes:27,includes:28,todayMarker:29,title:30,acc_title:31,acc_title_value:32,acc_descr:33,acc_descr_value:34,acc_descr_multiline_value:35,section:36,clickStatement:37,taskTxt:38,taskData:39,click:40,callbackname:41,callbackargs:42,href:43,clickStatementDebug:44,$accept:0,$end:1},terminals_:{2:"error",4:"gantt",6:"EOF",8:"SPACE",10:"NL",12:"weekday_monday",13:"weekday_tuesday",14:"weekday_wednesday",15:"weekday_thursday",16:"weekday_friday",17:"weekday_saturday",18:"weekday_sunday",20:"weekend_friday",21:"weekend_saturday",22:"dateFormat",23:"inclusiveEndDates",24:"topAxis",25:"axisFormat",26:"tickInterval",27:"excludes",28:"includes",29:"todayMarker",30:"title",31:"acc_title",32:"acc_title_value",33:"acc_descr",34:"acc_descr_value",35:"acc_descr_multiline_value",36:"section",38:"taskTxt",39:"taskData",40:"click",41:"callbackname",42:"callbackargs",43:"href"},productions_:[0,[3,3],[5,0],[5,2],[7,2],[7,1],[7,1],[7,1],[11,1],[11,1],[11,1],[11,1],[11,1],[11,1],[11,1],[19,1],[19,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,1],[9,2],[9,2],[9,1],[9,1],[9,1],[9,2],[37,2],[37,3],[37,3],[37,4],[37,3],[37,4],[37,2],[44,2],[44,3],[44,3],[44,4],[44,3],[44,4],[44,2]],performAction:c(function(o,l,y,g,w,s,z){var e=s.length-1;switch(w){case 1:return s[e-1];case 2:this.$=[];break;case 3:s[e-1].push(s[e]),this.$=s[e-1];break;case 4:case 5:this.$=s[e];break;case 6:case 7:this.$=[];break;case 8:g.setWeekday("monday");break;case 9:g.setWeekday("tuesday");break;case 10:g.setWeekday("wednesday");break;case 11:g.setWeekday("thursday");break;case 12:g.setWeekday("friday");break;case 13:g.setWeekday("saturday");break;case 14:g.setWeekday("sunday");break;case 15:g.setWeekend("friday");break;case 16:g.setWeekend("saturday");break;case 17:g.setDateFormat(s[e].substr(11)),this.$=s[e].substr(11);break;case 18:g.enableInclusiveEndDates(),this.$=s[e].substr(18);break;case 19:g.TopAxis(),this.$=s[e].substr(8);break;case 20:g.setAxisFormat(s[e].substr(11)),this.$=s[e].substr(11);break;case 21:g.setTickInterval(s[e].substr(13)),this.$=s[e].substr(13);break;case 22:g.setExcludes(s[e].substr(9)),this.$=s[e].substr(9);break;case 23:g.setIncludes(s[e].substr(9)),this.$=s[e].substr(9);break;case 24:g.setTodayMarker(s[e].substr(12)),this.$=s[e].substr(12);break;case 27:g.setDiagramTitle(s[e].substr(6)),this.$=s[e].substr(6);break;case 28:this.$=s[e].trim(),g.setAccTitle(this.$);break;case 29:case 30:this.$=s[e].trim(),g.setAccDescription(this.$);break;case 31:g.addSection(s[e].substr(8)),this.$=s[e].substr(8);break;case 33:g.addTask(s[e-1],s[e]),this.$="task";break;case 34:this.$=s[e-1],g.setClickEvent(s[e-1],s[e],null);break;case 35:this.$=s[e-2],g.setClickEvent(s[e-2],s[e-1],s[e]);break;case 36:this.$=s[e-2],g.setClickEvent(s[e-2],s[e-1],null),g.setLink(s[e-2],s[e]);break;case 37:this.$=s[e-3],g.setClickEvent(s[e-3],s[e-2],s[e-1]),g.setLink(s[e-3],s[e]);break;case 38:this.$=s[e-2],g.setClickEvent(s[e-2],s[e],null),g.setLink(s[e-2],s[e-1]);break;case 39:this.$=s[e-3],g.setClickEvent(s[e-3],s[e-1],s[e]),g.setLink(s[e-3],s[e-2]);break;case 40:this.$=s[e-1],g.setLink(s[e-1],s[e]);break;case 41:case 47:this.$=s[e-1]+" "+s[e];break;case 42:case 43:case 45:this.$=s[e-2]+" "+s[e-1]+" "+s[e];break;case 44:case 46:this.$=s[e-3]+" "+s[e-2]+" "+s[e-1]+" "+s[e];break}},"anonymous"),table:[{3:1,4:[1,2]},{1:[3]},t(r,[2,2],{5:3}),{6:[1,4],7:5,8:[1,6],9:7,10:[1,8],11:17,12:n,13:i,14:a,15:m,16:h,17:T,18:M,19:18,20:$,21:b,22:L,23:C,24:D,25:R,26:I,27:S,28:E,29:W,30:A,31:N,33:H,35:Y,36:p,37:24,38:d,40:u},t(r,[2,7],{1:[2,1]}),t(r,[2,3]),{9:36,11:17,12:n,13:i,14:a,15:m,16:h,17:T,18:M,19:18,20:$,21:b,22:L,23:C,24:D,25:R,26:I,27:S,28:E,29:W,30:A,31:N,33:H,35:Y,36:p,37:24,38:d,40:u},t(r,[2,5]),t(r,[2,6]),t(r,[2,17]),t(r,[2,18]),t(r,[2,19]),t(r,[2,20]),t(r,[2,21]),t(r,[2,22]),t(r,[2,23]),t(r,[2,24]),t(r,[2,25]),t(r,[2,26]),t(r,[2,27]),{32:[1,37]},{34:[1,38]},t(r,[2,30]),t(r,[2,31]),t(r,[2,32]),{39:[1,39]},t(r,[2,8]),t(r,[2,9]),t(r,[2,10]),t(r,[2,11]),t(r,[2,12]),t(r,[2,13]),t(r,[2,14]),t(r,[2,15]),t(r,[2,16]),{41:[1,40],43:[1,41]},t(r,[2,4]),t(r,[2,28]),t(r,[2,29]),t(r,[2,33]),t(r,[2,34],{42:[1,42],43:[1,43]}),t(r,[2,40],{41:[1,44]}),t(r,[2,35],{43:[1,45]}),t(r,[2,36]),t(r,[2,38],{42:[1,46]}),t(r,[2,37]),t(r,[2,39])],defaultActions:{},parseError:c(function(o,l){if(l.recoverable)this.trace(o);else{var y=new Error(o);throw y.hash=l,y}},"parseError"),parse:c(function(o){var l=this,y=[0],g=[],w=[null],s=[],z=this.table,e="",_=0,V=0,P=2,O=1,G=s.slice.call(arguments,1),F=Object.create(this.lexer),Q={yy:{}};for(var rt in this.yy)Object.prototype.hasOwnProperty.call(this.yy,rt)&&(Q.yy[rt]=this.yy[rt]);F.setInput(o,Q.yy),Q.yy.lexer=F,Q.yy.parser=this,typeof F.yylloc>"u"&&(F.yylloc={});var ot=F.yylloc;s.push(ot);var ht=F.options&&F.options.ranges;typeof Q.yy.parseError=="function"?this.parseError=Q.yy.parseError:this.parseError=Object.getPrototypeOf(this).parseError;function mt(U){y.length=y.length-2*U,w.length=w.length-U,s.length=s.length-U}c(mt,"popStack");function ct(){var U;return U=g.pop()||F.lex()||O,typeof U!="number"&&(U instanceof Array&&(g=U,U=g.pop()),U=l.symbols_[U]||U),U}c(ct,"lex");for(var B,Z,j,it,K={},st,J,Ut,pt;;){if(Z=y[y.length-1],this.defaultActions[Z]?j=this.defaultActions[Z]:((B===null||typeof B>"u")&&(B=ct()),j=z[Z]&&z[Z][B]),typeof j>"u"||!j.length||!j[0]){var Yt="";pt=[];for(st in z[Z])this.terminals_[st]&&st>P&&pt.push("'"+this.terminals_[st]+"'");F.showPosition?Yt="Parse error on line "+(_+1)+`:
`+F.showPosition()+`
Expecting `+pt.join(", ")+", got '"+(this.terminals_[B]||B)+"'":Yt="Parse error on line "+(_+1)+": Unexpected "+(B==O?"end of input":"'"+(this.terminals_[B]||B)+"'"),this.parseError(Yt,{text:F.match,token:this.terminals_[B]||B,line:F.yylineno,loc:ot,expected:pt})}if(j[0]instanceof Array&&j.length>1)throw new Error("Parse Error: multiple actions possible at state: "+Z+", token: "+B);switch(j[0]){case 1:y.push(B),w.push(F.yytext),s.push(F.yylloc),y.push(j[1]),B=null,V=F.yyleng,e=F.yytext,_=F.yylineno,ot=F.yylloc;break;case 2:if(J=this.productions_[j[1]][1],K.$=w[w.length-J],K._$={first_line:s[s.length-(J||1)].first_line,last_line:s[s.length-1].last_line,first_column:s[s.length-(J||1)].first_column,last_column:s[s.length-1].last_column},ht&&(K._$.range=[s[s.length-(J||1)].range[0],s[s.length-1].range[1]]),it=this.performAction.apply(K,[e,V,_,Q.yy,j[1],w,s].concat(G)),typeof it<"u")return it;J&&(y=y.slice(0,-1*J*2),w=w.slice(0,-1*J),s=s.slice(0,-1*J)),y.push(this.productions_[j[1]][0]),w.push(K.$),s.push(K._$),Ut=z[y[y.length-2]][y[y.length-1]],y.push(Ut);break;case 3:return!0}}return!0},"parse")},v=(function(){var f={EOF:1,parseError:c(function(l,y){if(this.yy.parser)this.yy.parser.parseError(l,y);else throw new Error(l)},"parseError"),setInput:c(function(o,l){return this.yy=l||this.yy||{},this._input=o,this._more=this._backtrack=this.done=!1,this.yylineno=this.yyleng=0,this.yytext=this.matched=this.match="",this.conditionStack=["INITIAL"],this.yylloc={first_line:1,first_column:0,last_line:1,last_column:0},this.options.ranges&&(this.yylloc.range=[0,0]),this.offset=0,this},"setInput"),input:c(function(){var o=this._input[0];this.yytext+=o,this.yyleng++,this.offset++,this.match+=o,this.matched+=o;var l=o.match(/(?:\r\n?|\n).*/g);return l?(this.yylineno++,this.yylloc.last_line++):this.yylloc.last_column++,this.options.ranges&&this.yylloc.range[1]++,this._input=this._input.slice(1),o},"input"),unput:c(function(o){var l=o.length,y=o.split(/(?:\r\n?|\n)/g);this._input=o+this._input,this.yytext=this.yytext.substr(0,this.yytext.length-l),this.offset-=l;var g=this.match.split(/(?:\r\n?|\n)/g);this.match=this.match.substr(0,this.match.length-1),this.matched=this.matched.substr(0,this.matched.length-1),y.length-1&&(this.yylineno-=y.length-1);var w=this.yylloc.range;return this.yylloc={first_line:this.yylloc.first_line,last_line:this.yylineno+1,first_column:this.yylloc.first_column,last_column:y?(y.length===g.length?this.yylloc.first_column:0)+g[g.length-y.length].length-y[0].length:this.yylloc.first_column-l},this.options.ranges&&(this.yylloc.range=[w[0],w[0]+this.yyleng-l]),this.yyleng=this.yytext.length,this},"unput"),more:c(function(){return this._more=!0,this},"more"),reject:c(function(){if(this.options.backtrack_lexer)this._backtrack=!0;else return this.parseError("Lexical error on line "+(this.yylineno+1)+`. You can only invoke reject() in the lexer when the lexer is of the backtracking persuasion (options.backtrack_lexer = true).
`+this.showPosition(),{text:"",token:null,line:this.yylineno});return this},"reject"),less:c(function(o){this.unput(this.match.slice(o))},"less"),pastInput:c(function(){var o=this.matched.substr(0,this.matched.length-this.match.length);return(o.length>20?"...":"")+o.substr(-20).replace(/\n/g,"")},"pastInput"),upcomingInput:c(function(){var o=this.match;return o.length<20&&(o+=this._input.substr(0,20-o.length)),(o.substr(0,20)+(o.length>20?"...":"")).replace(/\n/g,"")},"upcomingInput"),showPosition:c(function(){var o=this.pastInput(),l=new Array(o.length+1).join("-");return o+this.upcomingInput()+`
`+l+"^"},"showPosition"),test_match:c(function(o,l){var y,g,w;if(this.options.backtrack_lexer&&(w={yylineno:this.yylineno,yylloc:{first_line:this.yylloc.first_line,last_line:this.last_line,first_column:this.yylloc.first_column,last_column:this.yylloc.last_column},yytext:this.yytext,match:this.match,matches:this.matches,matched:this.matched,yyleng:this.yyleng,offset:this.offset,_more:this._more,_input:this._input,yy:this.yy,conditionStack:this.conditionStack.slice(0),done:this.done},this.options.ranges&&(w.yylloc.range=this.yylloc.range.slice(0))),g=o[0].match(/(?:\r\n?|\n).*/g),g&&(this.yylineno+=g.length),this.yylloc={first_line:this.yylloc.last_line,last_line:this.yylineno+1,first_column:this.yylloc.last_column,last_column:g?g[g.length-1].length-g[g.length-1].match(/\r?\n?/)[0].length:this.yylloc.last_column+o[0].length},this.yytext+=o[0],this.match+=o[0],this.matches=o,this.yyleng=this.yytext.length,this.options.ranges&&(this.yylloc.range=[this.offset,this.offset+=this.yyleng]),this._more=!1,this._backtrack=!1,this._input=this._input.slice(o[0].length),this.matched+=o[0],y=this.performAction.call(this,this.yy,this,l,this.conditionStack[this.conditionStack.length-1]),this.done&&this._input&&(this.done=!1),y)return y;if(this._backtrack){for(var s in w)this[s]=w[s];return!1}return!1},"test_match"),next:c(function(){if(this.done)return this.EOF;this._input||(this.done=!0);var o,l,y,g;this._more||(this.yytext="",this.match="");for(var w=this._currentRules(),s=0;s<w.length;s++)if(y=this._input.match(this.rules[w[s]]),y&&(!l||y[0].length>l[0].length)){if(l=y,g=s,this.options.backtrack_lexer){if(o=this.test_match(y,w[s]),o!==!1)return o;if(this._backtrack){l=!1;continue}else return!1}else if(!this.options.flex)break}return l?(o=this.test_match(l,w[g]),o!==!1?o:!1):this._input===""?this.EOF:this.parseError("Lexical error on line "+(this.yylineno+1)+`. Unrecognized text.
`+this.showPosition(),{text:"",token:null,line:this.yylineno})},"next"),lex:c(function(){var l=this.next();return l||this.lex()},"lex"),begin:c(function(l){this.conditionStack.push(l)},"begin"),popState:c(function(){var l=this.conditionStack.length-1;return l>0?this.conditionStack.pop():this.conditionStack[0]},"popState"),_currentRules:c(function(){return this.conditionStack.length&&this.conditionStack[this.conditionStack.length-1]?this.conditions[this.conditionStack[this.conditionStack.length-1]].rules:this.conditions.INITIAL.rules},"_currentRules"),topState:c(function(l){return l=this.conditionStack.length-1-Math.abs(l||0),l>=0?this.conditionStack[l]:"INITIAL"},"topState"),pushState:c(function(l){this.begin(l)},"pushState"),stateStackSize:c(function(){return this.conditionStack.length},"stateStackSize"),options:{"case-insensitive":!0},performAction:c(function(l,y,g,w){switch(g){case 0:return this.begin("open_directive"),"open_directive";case 1:return this.begin("acc_title"),31;case 2:return this.popState(),"acc_title_value";case 3:return this.begin("acc_descr"),33;case 4:return this.popState(),"acc_descr_value";case 5:this.begin("acc_descr_multiline");break;case 6:this.popState();break;case 7:return"acc_descr_multiline_value";case 8:break;case 9:break;case 10:break;case 11:return 10;case 12:break;case 13:break;case 14:this.begin("href");break;case 15:this.popState();break;case 16:return 43;case 17:this.begin("callbackname");break;case 18:this.popState();break;case 19:this.popState(),this.begin("callbackargs");break;case 20:return 41;case 21:this.popState();break;case 22:return 42;case 23:this.begin("click");break;case 24:this.popState();break;case 25:return 40;case 26:return 4;case 27:return 22;case 28:return 23;case 29:return 24;case 30:return 25;case 31:return 26;case 32:return 28;case 33:return 27;case 34:return 29;case 35:return 12;case 36:return 13;case 37:return 14;case 38:return 15;case 39:return 16;case 40:return 17;case 41:return 18;case 42:return 20;case 43:return 21;case 44:return"date";case 45:return 30;case 46:return"accDescription";case 47:return 36;case 48:return 38;case 49:return 39;case 50:return":";case 51:return 6;case 52:return"INVALID"}},"anonymous"),rules:[/^(?:%%\{)/i,/^(?:accTitle\s*:\s*)/i,/^(?:(?!\n||)*[^\n]*)/i,/^(?:accDescr\s*:\s*)/i,/^(?:(?!\n||)*[^\n]*)/i,/^(?:accDescr\s*\{\s*)/i,/^(?:[\}])/i,/^(?:[^\}]*)/i,/^(?:%%(?!\{)*[^\n]*)/i,/^(?:[^\}]%%*[^\n]*)/i,/^(?:%%*[^\n]*[\n]*)/i,/^(?:[\n]+)/i,/^(?:\s+)/i,/^(?:%[^\n]*)/i,/^(?:href[\s]+["])/i,/^(?:["])/i,/^(?:[^"]*)/i,/^(?:call[\s]+)/i,/^(?:\([\s]*\))/i,/^(?:\()/i,/^(?:[^(]*)/i,/^(?:\))/i,/^(?:[^)]*)/i,/^(?:click[\s]+)/i,/^(?:[\s\n])/i,/^(?:[^\s\n]*)/i,/^(?:gantt\b)/i,/^(?:dateFormat\s[^#\n;]+)/i,/^(?:inclusiveEndDates\b)/i,/^(?:topAxis\b)/i,/^(?:axisFormat\s[^#\n;]+)/i,/^(?:tickInterval\s[^#\n;]+)/i,/^(?:includes\s[^#\n;]+)/i,/^(?:excludes\s[^#\n;]+)/i,/^(?:todayMarker\s[^\n;]+)/i,/^(?:weekday\s+monday\b)/i,/^(?:weekday\s+tuesday\b)/i,/^(?:weekday\s+wednesday\b)/i,/^(?:weekday\s+thursday\b)/i,/^(?:weekday\s+friday\b)/i,/^(?:weekday\s+saturday\b)/i,/^(?:weekday\s+sunday\b)/i,/^(?:weekend\s+friday\b)/i,/^(?:weekend\s+saturday\b)/i,/^(?:\d\d\d\d-\d\d-\d\d\b)/i,/^(?:title\s[^\n]+)/i,/^(?:accDescription\s[^#\n;]+)/i,/^(?:section\s[^\n]+)/i,/^(?:[^:\n]+)/i,/^(?::[^#\n;]+)/i,/^(?::)/i,/^(?:$)/i,/^(?:.)/i],conditions:{acc_descr_multiline:{rules:[6,7],inclusive:!1},acc_descr:{rules:[4],inclusive:!1},acc_title:{rules:[2],inclusive:!1},callbackargs:{rules:[21,22],inclusive:!1},callbackname:{rules:[18,19,20],inclusive:!1},href:{rules:[15,16],inclusive:!1},click:{rules:[24,25],inclusive:!1},INITIAL:{rules:[0,1,3,5,8,9,10,11,12,13,14,17,23,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52],inclusive:!0}}};return f})();x.lexer=v;function k(){this.yy={}}return c(k,"Parser"),k.prototype=x,x.Parser=k,new k})();Lt.parser=Lt;var hr=Lt;X.extend(tr);X.extend(ir);X.extend(cr);var ce={friday:5,saturday:6},tt="",Vt="",zt=void 0,Rt="",kt=[],yt=[],Nt=new Map,Ht=[],Mt=[],ft="",Bt="",fe=["active","done","crit","milestone","vert"],qt=[],lt="",gt=!1,Gt=!1,Xt="sunday",Et="saturday",Ot=0,mr=c(function(){Ht=[],Mt=[],ft="",qt=[],St=0,Pt=void 0,Ct=void 0,q=[],tt="",Vt="",Bt="",zt=void 0,Rt="",kt=[],yt=[],gt=!1,Gt=!1,Ot=0,Nt=new Map,lt="",Ee(),Xt="sunday",Et="saturday"},"clear"),kr=c(function(t){lt=t},"setDiagramId"),yr=c(function(t){Vt=t},"setAxisFormat"),gr=c(function(){return Vt},"getAxisFormat"),pr=c(function(t){zt=t},"setTickInterval"),vr=c(function(){return zt},"getTickInterval"),xr=c(function(t){Rt=t},"setTodayMarker"),Tr=c(function(){return Rt},"getTodayMarker"),br=c(function(t){tt=t},"setDateFormat"),wr=c(function(){gt=!0},"enableInclusiveEndDates"),_r=c(function(){return gt},"endDatesAreInclusive"),Dr=c(function(){Gt=!0},"enableTopAxis"),Sr=c(function(){return Gt},"topAxisEnabled"),Cr=c(function(t){Bt=t},"setDisplayMode"),Mr=c(function(){return Bt},"getDisplayMode"),Er=c(function(){return tt},"getDateFormat"),Ir=c(function(t){kt=t.toLowerCase().split(/[\s,]+/)},"setIncludes"),Yr=c(function(){return kt},"getIncludes"),$r=c(function(t){yt=t.toLowerCase().split(/[\s,]+/)},"setExcludes"),Fr=c(function(){return yt},"getExcludes"),Ar=c(function(){return Nt},"getLinks"),Lr=c(function(t){ft=t,Ht.push(t)},"addSection"),Or=c(function(){return Ht},"getSections"),Wr=c(function(){let t=le();const r=10;let n=0;for(;!t&&n<r;)t=le(),n++;return Mt=q,Mt},"getTasks"),he=c(function(t,r,n,i){const a=t.format(r.trim()),m=t.format("YYYY-MM-DD");return i.includes(a)||i.includes(m)?!1:n.includes("weekends")&&(t.isoWeekday()===ce[Et]||t.isoWeekday()===ce[Et]+1)||n.includes(t.format("dddd").toLowerCase())?!0:n.includes(a)||n.includes(m)},"isInvalidDate"),Pr=c(function(t){Xt=t},"setWeekday"),Vr=c(function(){return Xt},"getWeekday"),zr=c(function(t){Et=t},"setWeekend"),me=c(function(t,r,n,i){if(!n.length||t.manualEndTime)return;let a;t.startTime instanceof Date?a=X(t.startTime):a=X(t.startTime,r,!0),a=a.add(1,"d");let m;t.endTime instanceof Date?m=X(t.endTime):m=X(t.endTime,r,!0);const[h,T]=Rr(a,m,r,n,i);t.endTime=h.toDate(),t.renderEndTime=T},"checkTaskDates"),Rr=c(function(t,r,n,i,a){let m=!1,h=null;const T=r.add(1e4,"d");for(;t<=r;){if(m||(h=r.toDate()),m=he(t,n,i,a),m&&(r=r.add(1,"d"),r>T))throw new Error("Failed to find a valid date that was not excluded by `excludes` after 10,000 iterations.");t=t.add(1,"d")}return[r,h]},"fixTaskDates"),Wt=c(function(t,r,n){if(n=n.trim(),c(T=>{const M=T.trim();return M==="x"||M==="X"},"isTimestampFormat")(r)&&/^\d+$/.test(n))return new Date(Number(n));const m=/^after\s+(?<ids>[\d\w- ]+)/.exec(n);if(m!==null){let T=null;for(const $ of m.groups.ids.split(" ")){let b=at($);b!==void 0&&(!T||b.endTime>T.endTime)&&(T=b)}if(T)return T.endTime;const M=new Date;return M.setHours(0,0,0,0),M}let h=X(n,r.trim(),!0);if(h.isValid())return h.toDate();{nt.debug("Invalid date:"+n),nt.debug("With date format:"+r.trim());const T=new Date(n);if(T===void 0||isNaN(T.getTime())||T.getFullYear()<-1e4||T.getFullYear()>1e4)throw new Error("Invalid date:"+n);return T}},"getStartDate"),ke=c(function(t){const r=/^(\d+(?:\.\d+)?)([Mdhmswy]|ms)$/.exec(t.trim());return r!==null?[Number.parseFloat(r[1]),r[2]]:[NaN,"ms"]},"parseDuration"),ye=c(function(t,r,n,i=!1){n=n.trim();const m=/^until\s+(?<ids>[\d\w- ]+)/.exec(n);if(m!==null){let b=null;for(const C of m.groups.ids.split(" ")){let D=at(C);D!==void 0&&(!b||D.startTime<b.startTime)&&(b=D)}if(b)return b.startTime;const L=new Date;return L.setHours(0,0,0,0),L}let h=X(n,r.trim(),!0);if(h.isValid())return i&&(h=h.add(1,"d")),h.toDate();let T=X(t);const[M,$]=ke(n);if(!Number.isNaN(M)){const b=T.add(M,$);b.isValid()&&(T=b)}return T.toDate()},"getEndDate"),St=0,dt=c(function(t){return t===void 0?(St=St+1,"task"+St):t},"parseId"),Nr=c(function(t,r){let n;r.substr(0,1)===":"?n=r.substr(1,r.length):n=r;const i=n.split(","),a={};jt(i,a,fe);for(let h=0;h<i.length;h++)i[h]=i[h].trim();let m="";switch(i.length){case 1:a.id=dt(),a.startTime=t.endTime,m=i[0];break;case 2:a.id=dt(),a.startTime=Wt(void 0,tt,i[0]),m=i[1];break;case 3:a.id=dt(i[0]),a.startTime=Wt(void 0,tt,i[1]),m=i[2];break}return m&&(a.endTime=ye(a.startTime,tt,m,gt),a.manualEndTime=X(m,"YYYY-MM-DD",!0).isValid(),me(a,tt,yt,kt)),a},"compileData"),Hr=c(function(t,r){let n;r.substr(0,1)===":"?n=r.substr(1,r.length):n=r;const i=n.split(","),a={};jt(i,a,fe);for(let m=0;m<i.length;m++)i[m]=i[m].trim();switch(i.length){case 1:a.id=dt(),a.startTime={type:"prevTaskEnd",id:t},a.endTime={data:i[0]};break;case 2:a.id=dt(),a.startTime={type:"getStartDate",startData:i[0]},a.endTime={data:i[1]};break;case 3:a.id=dt(i[0]),a.startTime={type:"getStartDate",startData:i[1]},a.endTime={data:i[2]};break}return a},"parseData"),Pt,Ct,q=[],ge={},Br=c(function(t,r){const n={section:ft,type:ft,processed:!1,manualEndTime:!1,renderEndTime:null,raw:{data:r},task:t,classes:[]},i=Hr(Ct,r);n.raw.startTime=i.startTime,n.raw.endTime=i.endTime,n.id=i.id,n.prevTaskId=Ct,n.active=i.active,n.done=i.done,n.crit=i.crit,n.milestone=i.milestone,n.vert=i.vert,n.order=Ot,Ot++;const a=q.push(n);Ct=n.id,ge[n.id]=a-1},"addTask"),at=c(function(t){const r=ge[t];return q[r]},"findTaskById"),qr=c(function(t,r){const n={section:ft,type:ft,description:t,task:t,classes:[]},i=Nr(Pt,r);n.startTime=i.startTime,n.endTime=i.endTime,n.id=i.id,n.active=i.active,n.done=i.done,n.crit=i.crit,n.milestone=i.milestone,n.vert=i.vert,Pt=n,Mt.push(n)},"addTaskOrg"),le=c(function(){const t=c(function(n){const i=q[n];let a="";switch(q[n].raw.startTime.type){case"prevTaskEnd":{const m=at(i.prevTaskId);i.startTime=m.endTime;break}case"getStartDate":a=Wt(void 0,tt,q[n].raw.startTime.startData),a&&(q[n].startTime=a);break}return q[n].startTime&&(q[n].endTime=ye(q[n].startTime,tt,q[n].raw.endTime.data,gt),q[n].endTime&&(q[n].processed=!0,q[n].manualEndTime=X(q[n].raw.endTime.data,"YYYY-MM-DD",!0).isValid(),me(q[n],tt,yt,kt))),q[n].processed},"compileTask");let r=!0;for(const[n,i]of q.entries())t(n),r=r&&i.processed;return r},"compileTasks"),Gr=c(function(t,r){let n=r;ut().securityLevel!=="loose"&&(n=Me.sanitizeUrl(r)),t.split(",").forEach(function(i){at(i)!==void 0&&(ve(i,()=>{window.open(n,"_self")}),Nt.set(i,n))}),pe(t,"clickable")},"setLink"),pe=c(function(t,r){t.split(",").forEach(function(n){let i=at(n);i!==void 0&&i.classes.push(r)})},"setClass"),Xr=c(function(t,r,n){if(ut().securityLevel!=="loose"||r===void 0)return;let i=[];if(typeof n=="string"){i=n.split(/,(?=(?:(?:[^"]*"){2})*[^"]*$)/);for(let m=0;m<i.length;m++){let h=i[m].trim();h.startsWith('"')&&h.endsWith('"')&&(h=h.substr(1,h.length-2)),i[m]=h}}i.length===0&&i.push(t),at(t)!==void 0&&ve(t,()=>{Ie.runFunc(r,...i)})},"setClickFun"),ve=c(function(t,r){qt.push(function(){const n=lt?`${lt}-${t}`:t,i=document.querySelector(`[id="${n}"]`);i!==null&&i.addEventListener("click",function(){r()})},function(){const n=lt?`${lt}-${t}`:t,i=document.querySelector(`[id="${n}-text"]`);i!==null&&i.addEventListener("click",function(){r()})})},"pushFun"),jr=c(function(t,r,n){t.split(",").forEach(function(i){Xr(i,r,n)}),pe(t,"clickable")},"setClickEvent"),Ur=c(function(t){qt.forEach(function(r){r(t)})},"bindFunctions"),Zr={getConfig:c(()=>ut().gantt,"getConfig"),clear:mr,setDateFormat:br,getDateFormat:Er,enableInclusiveEndDates:wr,endDatesAreInclusive:_r,enableTopAxis:Dr,topAxisEnabled:Sr,setAxisFormat:yr,getAxisFormat:gr,setTickInterval:pr,getTickInterval:vr,setTodayMarker:xr,getTodayMarker:Tr,setAccTitle:De,getAccTitle:_e,setDiagramTitle:we,getDiagramTitle:be,setDiagramId:kr,setDisplayMode:Cr,getDisplayMode:Mr,setAccDescription:Te,getAccDescription:xe,addSection:Lr,getSections:Or,getTasks:Wr,addTask:Br,findTaskById:at,addTaskOrg:qr,setIncludes:Ir,getIncludes:Yr,setExcludes:$r,getExcludes:Fr,setClickEvent:jr,setLink:Gr,getLinks:Ar,bindFunctions:Ur,parseDuration:ke,isInvalidDate:he,setWeekday:Pr,getWeekday:Vr,setWeekend:zr};function jt(t,r,n){let i=!0;for(;i;)i=!1,n.forEach(function(a){const m="^\\s*"+a+"\\s*$",h=new RegExp(m);t[0].match(h)&&(r[a]=!0,t.shift(1),i=!0)})}c(jt,"getTaskTags");X.extend(fr);var Qr=c(function(){nt.debug("Something is calling, setConf, remove the call")},"setConf"),ue={monday:Re,tuesday:ze,wednesday:Ve,thursday:Pe,friday:We,saturday:Oe,sunday:Le},Kr=c((t,r)=>{let n=[...t].map(()=>-1/0),i=[...t].sort((m,h)=>m.startTime-h.startTime||m.order-h.order),a=0;for(const m of i)for(let h=0;h<n.length;h++)if(m.startTime>=n[h]){n[h]=m.endTime,m.order=h+r,h>a&&(a=h);break}return a},"getMaxIntersections"),et,Ft=1e4,Jr=c(function(t,r,n,i){const a=ut().gantt;i.db.setDiagramId(r);const m=ut().securityLevel;let h;m==="sandbox"&&(h=vt("#i"+r));const T=m==="sandbox"?vt(h.nodes()[0].contentDocument.body):vt("body"),M=m==="sandbox"?h.nodes()[0].contentDocument:document,$=M.getElementById(r);et=$.parentElement.offsetWidth,et===void 0&&(et=1200),a.useWidth!==void 0&&(et=a.useWidth);const b=i.db.getTasks();let L=[];for(const u of b)L.push(u.type);L=d(L);const C={};let D=2*a.topPadding;if(i.db.getDisplayMode()==="compact"||a.displayMode==="compact"){const u={};for(const v of b)u[v.section]===void 0?u[v.section]=[v]:u[v.section].push(v);let x=0;for(const v of Object.keys(u)){const k=Kr(u[v],x)+1;x+=k,D+=k*(a.barHeight+a.barGap),C[v]=k}}else{D+=b.length*(a.barHeight+a.barGap);for(const u of L)C[u]=b.filter(x=>x.type===u).length}$.setAttribute("viewBox","0 0 "+et+" "+D);const R=T.select(`[id="${r}"]`),I=Ye().domain([$e(b,function(u){return u.startTime}),Fe(b,function(u){return u.endTime})]).rangeRound([0,et-a.leftPadding-a.rightPadding]);function S(u,x){const v=u.startTime,k=x.startTime;let f=0;return v>k?f=1:v<k&&(f=-1),f}c(S,"taskCompare"),b.sort(S),E(b,et,D),Se(R,D,et,a.useMaxWidth),R.append("text").text(i.db.getDiagramTitle()).attr("x",et/2).attr("y",a.titleTopMargin).attr("class","titleText");function E(u,x,v){const k=a.barHeight,f=k+a.barGap,o=a.topPadding,l=a.leftPadding,y=Ne().domain([0,L.length]).range(["#00B9FA","#F95002"]).interpolate(Ae);A(f,o,l,x,v,u,i.db.getExcludes(),i.db.getIncludes()),H(l,o,x,v),W(u,f,o,l,k,y,x),Y(f,o),p(l,o,x,v)}c(E,"makeGantt");function W(u,x,v,k,f,o,l){u.sort((e,_)=>e.vert===_.vert?0:e.vert?1:-1);const g=[...new Set(u.map(e=>e.order))].map(e=>u.find(_=>_.order===e));R.append("g").selectAll("rect").data(g).enter().append("rect").attr("x",0).attr("y",function(e,_){return _=e.order,_*x+v-2}).attr("width",function(){return l-a.rightPadding/2}).attr("height",x).attr("class",function(e){for(const[_,V]of L.entries())if(e.type===V)return"section section"+_%a.numberSectionStyles;return"section section0"}).enter();const w=R.append("g").selectAll("rect").data(u).enter(),s=i.db.getLinks();if(w.append("rect").attr("id",function(e){return r+"-"+e.id}).attr("rx",3).attr("ry",3).attr("x",function(e){return e.milestone?I(e.startTime)+k+.5*(I(e.endTime)-I(e.startTime))-.5*f:I(e.startTime)+k}).attr("y",function(e,_){return _=e.order,e.vert?a.gridLineStartPadding:_*x+v}).attr("width",function(e){return e.milestone?f:e.vert?.08*f:I(e.renderEndTime||e.endTime)-I(e.startTime)}).attr("height",function(e){return e.vert?b.length*(a.barHeight+a.barGap)+a.barHeight*2:f}).attr("transform-origin",function(e,_){return _=e.order,(I(e.startTime)+k+.5*(I(e.endTime)-I(e.startTime))).toString()+"px "+(_*x+v+.5*f).toString()+"px"}).attr("class",function(e){const _="task";let V="";e.classes.length>0&&(V=e.classes.join(" "));let P=0;for(const[G,F]of L.entries())e.type===F&&(P=G%a.numberSectionStyles);let O="";return e.active?e.crit?O+=" activeCrit":O=" active":e.done?e.crit?O=" doneCrit":O=" done":e.crit&&(O+=" crit"),O.length===0&&(O=" task"),e.milestone&&(O=" milestone "+O),e.vert&&(O=" vert "+O),O+=P,O+=" "+V,_+O}),w.append("text").attr("id",function(e){return r+"-"+e.id+"-text"}).text(function(e){return e.task}).attr("font-size",a.fontSize).attr("x",function(e){let _=I(e.startTime),V=I(e.renderEndTime||e.endTime);if(e.milestone&&(_+=.5*(I(e.endTime)-I(e.startTime))-.5*f,V=_+f),e.vert)return I(e.startTime)+k;const P=this.getBBox().width;return P>V-_?V+P+1.5*a.leftPadding>l?_+k-5:V+k+5:(V-_)/2+_+k}).attr("y",function(e,_){return e.vert?a.gridLineStartPadding+b.length*(a.barHeight+a.barGap)+60:(_=e.order,_*x+a.barHeight/2+(a.fontSize/2-2)+v)}).attr("text-height",f).attr("class",function(e){const _=I(e.startTime);let V=I(e.endTime);e.milestone&&(V=_+f);const P=this.getBBox().width;let O="";e.classes.length>0&&(O=e.classes.join(" "));let G=0;for(const[Q,rt]of L.entries())e.type===rt&&(G=Q%a.numberSectionStyles);let F="";return e.active&&(e.crit?F="activeCritText"+G:F="activeText"+G),e.done?e.crit?F=F+" doneCritText"+G:F=F+" doneText"+G:e.crit&&(F=F+" critText"+G),e.milestone&&(F+=" milestoneText"),e.vert&&(F+=" vertText"),P>V-_?V+P+1.5*a.leftPadding>l?O+" taskTextOutsideLeft taskTextOutside"+G+" "+F:O+" taskTextOutsideRight taskTextOutside"+G+" "+F+" width-"+P:O+" taskText taskText"+G+" "+F+" width-"+P}),ut().securityLevel==="sandbox"){let e;e=vt("#i"+r);const _=e.nodes()[0].contentDocument;w.filter(function(V){return s.has(V.id)}).each(function(V){var P=_.querySelector("#"+CSS.escape(r+"-"+V.id)),O=_.querySelector("#"+CSS.escape(r+"-"+V.id+"-text"));const G=P.parentNode;var F=_.createElement("a");F.setAttribute("xlink:href",s.get(V.id)),F.setAttribute("target","_top"),G.appendChild(F),F.appendChild(P),F.appendChild(O)})}}c(W,"drawRects");function A(u,x,v,k,f,o,l,y){if(l.length===0&&y.length===0)return;let g,w;for(const{startTime:P,endTime:O}of o)(g===void 0||P<g)&&(g=P),(w===void 0||O>w)&&(w=O);if(!g||!w)return;if(X(w).diff(X(g),"year")>5){nt.warn("The difference between the min and max time is more than 5 years. This will cause performance issues. Skipping drawing exclude days.");return}const s=i.db.getDateFormat(),z=[];let e=null,_=X(g);for(;_.valueOf()<=w;)i.db.isInvalidDate(_,s,l,y)?e?e.end=_:e={start:_,end:_}:e&&(z.push(e),e=null),_=_.add(1,"d");R.append("g").selectAll("rect").data(z).enter().append("rect").attr("id",P=>r+"-exclude-"+P.start.format("YYYY-MM-DD")).attr("x",P=>I(P.start.startOf("day"))+v).attr("y",a.gridLineStartPadding).attr("width",P=>I(P.end.endOf("day"))-I(P.start.startOf("day"))).attr("height",f-x-a.gridLineStartPadding).attr("transform-origin",function(P,O){return(I(P.start)+v+.5*(I(P.end)-I(P.start))).toString()+"px "+(O*u+.5*f).toString()+"px"}).attr("class","exclude-range")}c(A,"drawExcludeDays");function N(u,x,v,k){if(v<=0||u>x)return 1/0;const f=x-u,o=X.duration({[k??"day"]:v}).asMilliseconds();return o<=0?1/0:Math.ceil(f/o)}c(N,"getEstimatedTickCount");function H(u,x,v,k){const f=i.db.getDateFormat(),o=i.db.getAxisFormat();let l;o?l=o:f==="D"?l="%d":l=a.axisFormat??"%Y-%m-%d";let y=Ze(I).tickSize(-k+x+a.gridLineStartPadding).tickFormat(Zt(l));const w=/^([1-9]\d*)(millisecond|second|minute|hour|day|week|month)$/.exec(i.db.getTickInterval()||a.tickInterval);if(w!==null){const s=parseInt(w[1],10);if(isNaN(s)||s<=0)nt.warn(`Invalid tick interval value: "${w[1]}". Skipping custom tick interval.`);else{const z=w[2],e=i.db.getWeekday()||a.weekday,_=I.domain(),V=_[0],P=_[1],O=N(V,P,s,z);if(O>Ft)nt.warn(`The tick interval "${s}${z}" would generate ${O} ticks, which exceeds the maximum allowed (${Ft}). This may indicate an invalid date or time range. Skipping custom tick interval.`);else switch(z){case"millisecond":y.ticks(re.every(s));break;case"second":y.ticks(ee.every(s));break;case"minute":y.ticks(te.every(s));break;case"hour":y.ticks(Jt.every(s));break;case"day":y.ticks(Kt.every(s));break;case"week":y.ticks(ue[e].every(s));break;case"month":y.ticks(Qt.every(s));break}}}if(R.append("g").attr("class","grid").attr("transform","translate("+u+", "+(k-50)+")").call(y).selectAll("text").style("text-anchor","middle").attr("fill","#000").attr("stroke","none").attr("font-size",10).attr("dy","1em"),i.db.topAxisEnabled()||a.topAxis){let s=Ue(I).tickSize(-k+x+a.gridLineStartPadding).tickFormat(Zt(l));if(w!==null){const z=parseInt(w[1],10);if(isNaN(z)||z<=0)nt.warn(`Invalid tick interval value: "${w[1]}". Skipping custom tick interval.`);else{const e=w[2],_=i.db.getWeekday()||a.weekday,V=I.domain(),P=V[0],O=V[1];if(N(P,O,z,e)<=Ft)switch(e){case"millisecond":s.ticks(re.every(z));break;case"second":s.ticks(ee.every(z));break;case"minute":s.ticks(te.every(z));break;case"hour":s.ticks(Jt.every(z));break;case"day":s.ticks(Kt.every(z));break;case"week":s.ticks(ue[_].every(z));break;case"month":s.ticks(Qt.every(z));break}}}R.append("g").attr("class","grid").attr("transform","translate("+u+", "+x+")").call(s).selectAll("text").style("text-anchor","middle").attr("fill","#000").attr("stroke","none").attr("font-size",10)}}c(H,"makeGrid");function Y(u,x){let v=0;const k=Object.keys(C).map(f=>[f,C[f]]);R.append("g").selectAll("text").data(k).enter().append(function(f){const o=f[0].split(Ce.lineBreakRegex),l=-(o.length-1)/2,y=M.createElementNS("http://www.w3.org/2000/svg","text");y.setAttribute("dy",l+"em");for(const[g,w]of o.entries()){const s=M.createElementNS("http://www.w3.org/2000/svg","tspan");s.setAttribute("alignment-baseline","central"),s.setAttribute("x","10"),g>0&&s.setAttribute("dy","1em"),s.textContent=w,y.appendChild(s)}return y}).attr("x",10).attr("y",function(f,o){if(o>0)for(let l=0;l<o;l++)return v+=k[o-1][1],f[1]*u/2+v*u+x;else return f[1]*u/2+x}).attr("font-size",a.sectionFontSize).attr("class",function(f){for(const[o,l]of L.entries())if(f[0]===l)return"sectionTitle sectionTitle"+o%a.numberSectionStyles;return"sectionTitle"})}c(Y,"vertLabels");function p(u,x,v,k){const f=i.db.getTodayMarker();if(f==="off")return;const o=R.append("g").attr("class","today"),l=new Date,y=o.append("line");y.attr("x1",I(l)+u).attr("x2",I(l)+u).attr("y1",a.titleTopMargin).attr("y2",k-a.titleTopMargin).attr("class","today"),f!==""&&y.attr("style",f.replace(/,/g,";"))}c(p,"drawToday");function d(u){const x={},v=[];for(let k=0,f=u.length;k<f;++k)Object.prototype.hasOwnProperty.call(x,u[k])||(x[u[k]]=!0,v.push(u[k]));return v}c(d,"checkUnique")},"draw"),ts={setConf:Qr,draw:Jr},es=c(t=>`
  .mermaid-main-font {
        font-family: ${t.fontFamily};
  }

  .exclude-range {
    fill: ${t.excludeBkgColor};
  }

  .section {
    stroke: none;
    opacity: 0.2;
  }

  .section0 {
    fill: ${t.sectionBkgColor};
  }

  .section2 {
    fill: ${t.sectionBkgColor2};
  }

  .section1,
  .section3 {
    fill: ${t.altSectionBkgColor};
    opacity: 0.2;
  }

  .sectionTitle0 {
    fill: ${t.titleColor};
  }

  .sectionTitle1 {
    fill: ${t.titleColor};
  }

  .sectionTitle2 {
    fill: ${t.titleColor};
  }

  .sectionTitle3 {
    fill: ${t.titleColor};
  }

  .sectionTitle {
    text-anchor: start;
    font-family: ${t.fontFamily};
  }


  /* Grid and axis */

  .grid .tick {
    stroke: ${t.gridColor};
    opacity: 0.8;
    shape-rendering: crispEdges;
  }

  .grid .tick text {
    font-family: ${t.fontFamily};
    fill: ${t.textColor};
  }

  .grid path {
    stroke-width: 0;
  }


  /* Today line */

  .today {
    fill: none;
    stroke: ${t.todayLineColor};
    stroke-width: 2px;
  }


  /* Task styling */

  /* Default task */

  .task {
    stroke-width: 2;
  }

  .taskText {
    text-anchor: middle;
    font-family: ${t.fontFamily};
  }

  .taskTextOutsideRight {
    fill: ${t.taskTextDarkColor};
    text-anchor: start;
    font-family: ${t.fontFamily};
  }

  .taskTextOutsideLeft {
    fill: ${t.taskTextDarkColor};
    text-anchor: end;
  }


  /* Special case clickable */

  .task.clickable {
    cursor: pointer;
  }

  .taskText.clickable {
    cursor: pointer;
    fill: ${t.taskTextClickableColor} !important;
    font-weight: bold;
  }

  .taskTextOutsideLeft.clickable {
    cursor: pointer;
    fill: ${t.taskTextClickableColor} !important;
    font-weight: bold;
  }

  .taskTextOutsideRight.clickable {
    cursor: pointer;
    fill: ${t.taskTextClickableColor} !important;
    font-weight: bold;
  }


  /* Specific task settings for the sections*/

  .taskText0,
  .taskText1,
  .taskText2,
  .taskText3 {
    fill: ${t.taskTextColor};
  }

  .task0,
  .task1,
  .task2,
  .task3 {
    fill: ${t.taskBkgColor};
    stroke: ${t.taskBorderColor};
  }

  .taskTextOutside0,
  .taskTextOutside2
  {
    fill: ${t.taskTextOutsideColor};
  }

  .taskTextOutside1,
  .taskTextOutside3 {
    fill: ${t.taskTextOutsideColor};
  }


  /* Active task */

  .active0,
  .active1,
  .active2,
  .active3 {
    fill: ${t.activeTaskBkgColor};
    stroke: ${t.activeTaskBorderColor};
  }

  .activeText0,
  .activeText1,
  .activeText2,
  .activeText3 {
    fill: ${t.taskTextDarkColor} !important;
  }


  /* Completed task */

  .done0,
  .done1,
  .done2,
  .done3 {
    stroke: ${t.doneTaskBorderColor};
    fill: ${t.doneTaskBkgColor};
    stroke-width: 2;
  }

  .doneText0,
  .doneText1,
  .doneText2,
  .doneText3 {
    fill: ${t.taskTextDarkColor} !important;
  }

  /* Done task text displayed outside the bar sits against the diagram background,
     not against the done-task bar, so it must use the outside/contrast color. */
  .doneText0.taskTextOutsideLeft,
  .doneText0.taskTextOutsideRight,
  .doneText1.taskTextOutsideLeft,
  .doneText1.taskTextOutsideRight,
  .doneText2.taskTextOutsideLeft,
  .doneText2.taskTextOutsideRight,
  .doneText3.taskTextOutsideLeft,
  .doneText3.taskTextOutsideRight {
    fill: ${t.taskTextOutsideColor} !important;
  }


  /* Tasks on the critical line */

  .crit0,
  .crit1,
  .crit2,
  .crit3 {
    stroke: ${t.critBorderColor};
    fill: ${t.critBkgColor};
    stroke-width: 2;
  }

  .activeCrit0,
  .activeCrit1,
  .activeCrit2,
  .activeCrit3 {
    stroke: ${t.critBorderColor};
    fill: ${t.activeTaskBkgColor};
    stroke-width: 2;
  }

  .doneCrit0,
  .doneCrit1,
  .doneCrit2,
  .doneCrit3 {
    stroke: ${t.critBorderColor};
    fill: ${t.doneTaskBkgColor};
    stroke-width: 2;
    cursor: pointer;
    shape-rendering: crispEdges;
  }

  .milestone {
    transform: rotate(45deg) scale(0.8,0.8);
  }

  .milestoneText {
    font-style: italic;
  }
  .doneCritText0,
  .doneCritText1,
  .doneCritText2,
  .doneCritText3 {
    fill: ${t.taskTextDarkColor} !important;
  }

  /* Done-crit task text outside the bar — same reasoning as doneText above. */
  .doneCritText0.taskTextOutsideLeft,
  .doneCritText0.taskTextOutsideRight,
  .doneCritText1.taskTextOutsideLeft,
  .doneCritText1.taskTextOutsideRight,
  .doneCritText2.taskTextOutsideLeft,
  .doneCritText2.taskTextOutsideRight,
  .doneCritText3.taskTextOutsideLeft,
  .doneCritText3.taskTextOutsideRight {
    fill: ${t.taskTextOutsideColor} !important;
  }

  .vert {
    stroke: ${t.vertLineColor};
  }

  .vertText {
    font-size: 15px;
    text-anchor: middle;
    fill: ${t.vertLineColor} !important;
  }

  .activeCritText0,
  .activeCritText1,
  .activeCritText2,
  .activeCritText3 {
    fill: ${t.taskTextDarkColor} !important;
  }

  .titleText {
    text-anchor: middle;
    font-size: 18px;
    fill: ${t.titleColor||t.textColor};
    font-family: ${t.fontFamily};
  }
`,"getStyles"),rs=es,us={parser:hr,db:Zr,renderer:ts,styles:rs};export{us as diagram};
