function makeReportImages() {
  const preview=$('#checkReportView');
  const width=660, margin=36, maxHeight=2400;
  const context=document.createElement('canvas').getContext('2d');
  const ink='#173e32', green='#105642';
  const font='system-ui, sans-serif';
  const contentWidth=width-margin*2;
  const title=preview.querySelector('.summaryTitle').textContent.trim();
  const fields=[...preview.querySelectorAll('.reportField,.reportResultBox')].map(field=>
    field.querySelector('small').textContent.trim()+'　'+field.querySelector('b').textContent.trim());
  const items=[...preview.querySelectorAll('.reportNameItem,.reportEmpty')].map(row=>
    row.matches('.reportEmpty') ? [row.textContent.trim()] : [row.querySelector('b').textContent.trim(),row.querySelector('span')?.textContent.trim()].filter(Boolean));
  const lines=[];
  function add(text,size,bold=false,background=null){
    const style=(bold?'700 ':'400 ')+size+'px '+font;
    context.font=style;
    let line='';
    for(const character of text){
      if(character==='\n'||(line&&context.measureText(line+character).width>contentWidth-(background?30:0))){
        lines.push({text:line,style,size,background});
        line=character==='\n'?'':character;
      }else line+=character;
    }
    lines.push({text:line,style,size,background});
  }
  fields.forEach(text=>add(text,21));
  add('核對明細',22,true);
  items.forEach((texts,index)=>texts.forEach((text,i)=>add(text,i?19:22,!i,index%2?'#edf7ef':'#f4f7f5')));

  const pages=[];
  let page=[], height=120;
  for(const line of lines){
    const lineHeight=line.size+14;
    if(height+lineHeight>maxHeight-40){pages.push({lines:page,height:height+40});page=[];height=120}
    page.push(line);height+=lineHeight;
  }
  pages.push({lines:page,height:height+40});
  if(pages.length>40)throw new Error('回報太長，請使用「匯出完整報告」。');
  return pages.map(({lines,height},index)=>{
    const canvas=document.createElement('canvas');
    canvas.width=width*2;canvas.height=height*2;
    const ctx=canvas.getContext('2d',{alpha:false});
    ctx.scale(2,2);
    ctx.fillStyle='#fff';ctx.fillRect(0,0,width,height);
    ctx.fillStyle=green;ctx.fillRect(0,0,width,94);
    ctx.fillStyle='#fff';ctx.font='700 29px '+font;ctx.textBaseline='middle';
    ctx.fillText(title,margin,47);
    if(pages.length>1){ctx.textAlign='right';ctx.font='400 18px '+font;ctx.fillText((index+1)+' / '+pages.length,width-margin,47);ctx.textAlign='left'}
    let y=110;
    for(const line of lines){
      const lineHeight=line.size+14;
      if(line.background){ctx.fillStyle=line.background;ctx.fillRect(margin,y,contentWidth,lineHeight)}
      ctx.fillStyle=ink;ctx.font=line.style;ctx.fillText(line.text,margin+(line.background?14:0),y+lineHeight/2);
      y+=lineHeight;
    }
    const encoded=canvas.toDataURL('image/png').split(',')[1];
    canvas.width=canvas.height=0;
    if(!encoded)throw new Error('無法製作回報圖片。');
    return encoded;
  });
}

async function shareCheckReport(){
  if(!state.task||inspectionBusy())return;
  const button=$('#reportCloseBtn'), back=$('#reportBackBtn'), status=$('#reportShareStatus');
  state.exportBusy=true;button.disabled=back.disabled=true;status.textContent='正在製作圖片…';
  try{
    await new Promise(resolve=>setTimeout(resolve,16));
    if($('#checkReportModal').classList.contains('hidden'))return;
    const images=makeReportImages();
    const name='MES核對回報_'+state.task.w.replace(/[^a-zA-Z0-9_-]/g,'_').slice(0,65);
    if(HAS_NATIVE_MES)await mesNativeRequest('shareReport',{name,images});
    else if(navigator.share){
      const files=images.map((data,i)=>new File([mesFromBase64(data)],name+(images.length>1?'_'+(i+1):'')+'.png',{type:'image/png'}));
      if(!navigator.canShare?.({files}))throw new Error('這個瀏覽器無法分享圖片，請從巡檢 App 操作。');
      await navigator.share({files});
    }else throw new Error('請在巡檢 App 分享圖片。');
    status.textContent='';
  }catch(error){status.textContent=error.name==='AbortError'?'':error.message}
  finally{state.exportBusy=false;button.disabled=back.disabled=false}
}
