(() => {
  const channel=window.webkit?.messageHandlers?.mesIOS;
  if (!channel) return;
  const send=(action,args={})=>channel.postMessage({action,...args});
  const request=(action,args,id)=>send(action,args).then(
    value=>window.__mesNativeResolve(id,value,''),
    error=>window.__mesNativeResolve(id,'',error?.message||String(error)));
  const errorText=error=>error?.message||String(error);
  function blob(base64) {
    return new Blob([Uint8Array.from(atob(base64),c=>c.charCodeAt(0))],{type:'image/jpeg'});
  }
  window.MESIOS=Object.freeze({
    get:(group,key)=>send('get',{group,key}),
    put:(group,key,value)=>send('put',{group,key,value}),
    removePhotos:keys=>send('removePhotos',{keys}),
    captureData:async token=>blob(await send('captureData',{token})),
    singlePhoto:async()=>{
      const value=await send('singlePhoto');
      return value?blob(value):null;
    }
  });
  window.NativeMES=Object.freeze({
    isIOS:()=>true,
    recognize:(data,mode,id)=>request('recognize',{data,mode},id),
    inflate:(data,id)=>request('inflate',{data},id),
    saveFile:(name,type,data,id)=>request('save',{name,type,data},id),
    shareReport:(name,images,id)=>request('shareReport',{name,images},id),
    scan:mode=>send('scan',{mode}).then(
      value=>window.__mesNativeScanResult(mode,value,''),
      error=>window.__mesNativeScanResult(mode,'',errorText(error))),
    startPhotoSession:()=>send('capture',{document:false}).catch(error=>
      window.__mesCameraEvent('finished',errorText(error))),
    startBomCapture:()=>send('capture',{document:true}).catch(error=>
      window.__mesBomCapture('finished',errorText(error))),
    finishPhotoSession:()=>send('finishCapture').catch(()=>{}),
    photoSessionProgress:count=>send('progress',{count}).catch(()=>{}),
    releaseSessionPhoto:token=>send('releaseCapture',{token}).catch(()=>{})
  });
})();
