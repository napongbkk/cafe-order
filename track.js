/* Coconut POS visitor count: one random id per browser, one call per page load. No personal data is sent. */
(function(){
  var SB='https://roggqmvmgfxsxynulpvk.supabase.co',KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJvZ2dxbXZtZ2Z4c3h5bnVscHZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA2ODg4MDgsImV4cCI6MjEwNjI2NDgwOH0.AUWbGcVDNTud5BlYMlTXRh-vP-1SVqfcbe1ukiC-4ec';
  function vid(){try{var v=localStorage.getItem('cp_vid');if(!v||!/^[A-Za-z0-9]{8,40}$/.test(v)){v=(Math.random().toString(36).slice(2)+Date.now().toString(36)).replace(/[^a-z0-9]/gi,'').slice(0,24);localStorage.setItem('cp_vid',v)}return v}catch(e){return ''}}
  window.CP_VID=vid;
  window.cpTrack=function(page,slug,client){var v=vid();if(!v||!page)return;
    if(client&&client.rpc){try{client.rpc('pos_track',{p_page:page,p_vid:v,p_slug:slug||null}).then(function(){},function(){})}catch(e){}return}
    try{fetch(SB+'/rest/v1/rpc/pos_track',{method:'POST',keepalive:true,headers:{apikey:KEY,Authorization:'Bearer '+KEY,'Content-Type':'application/json'},body:JSON.stringify({p_page:page,p_vid:v,p_slug:slug||null})}).catch(function(){})}catch(e){}};
  var s=document.currentScript,p=s&&s.getAttribute('data-page');
  if(p){var slug=p==='order'?((location.pathname.match(/^\/s\/([^\/?#]+)/)||[])[1]||new URLSearchParams(location.search).get('s')||''):'';window.cpTrack(p,slug)}
})();
