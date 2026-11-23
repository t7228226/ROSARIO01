/* The photo import produces draft rows. Only confirmed text enters the existing BOM parser. */
const bomPhotoParser = (() => {
  const MAX_ROWS = 120;
  const clean = value => String(value).normalize('NFKC').trim().toUpperCase()
    .replace(/[‐‑‒–—−]/g, '-');
  const workPattern = /^(?=[A-Z0-9]*[A-Z])[A-Z0-9]{4,8}-\d{8,12}$/;
  const materialPattern = /^(?=.*[A-Z])(?=.*\d)[A-Z0-9][A-Z0-9./_-]{6,62}[A-Z0-9]$/;
  const editableCode = value => /^[A-Z0-9][A-Z0-9./_-]{0,63}$/.test(value);
  const median = values => {
    const sorted = [...values].sort((a,b) => a-b);
    return sorted[Math.floor(sorted.length/2)];
  };

  function findSerials(tokens) {
    const numbers = tokens.filter(t => /^[1-9]\d{0,2}$/.test(t.value) && t.l < .48)
      .map(t => ({...t, n:Number(t.value)})).sort((a,b) => a.y-b.y);
    let best = [];
    // Score an aligned, increasing column. Right edges also work for right-aligned serials.
    for (const first of numbers) {
      const column = [first];
      for (const t of numbers) {
        const last = column.at(-1);
        const step = t.n-last.n;
        if (step < 1 || step > 4 || Math.abs(t.r-first.r) > .028) continue;
        const pitch = (t.y-last.y)/step;
        if (pitch < .009 || pitch > .24) continue;
        if (column.length > 1) {
          const expected = (last.y-first.y)/(last.n-first.n);
          if (pitch < expected*.52 || pitch > expected*1.65) continue;
        }
        column.push(t);
      }
      if (column.length > best.length || (column.length === best.length && first.n < best[0]?.n)) best = column;
    }
    return best;
  }

  function materialTokens(tokens) {
    const candidates = [];
    for (const token of tokens) {
      if (workPattern.test(token.value)) continue;
      if (materialPattern.test(token.value) && !token.value.endsWith('-')) candidates.push(token);
      // A split code is rejoined only where the printed hyphen identifies the boundary.
      if (!token.value.endsWith('-')) continue;
      const suffix = tokens.filter(t => t.l >= token.r-.003 && t.l < token.r+.02 &&
        Math.abs(t.y-token.y) < .008 && /^[A-Z0-9]{1,6}$/.test(t.value))
        .sort((a,b) => a.l-b.l)[0];
      if (suffix && materialPattern.test(token.value+suffix.value)) {
        candidates.push({...token, value:token.value+suffix.value, r:suffix.r});
      }
    }
    return candidates;
  }

  function parse(elements, crop = null) {
    const tokens = elements.map(([raw,l,y,r]) => ({value:clean(raw),l,y,r})).filter(t => t.value);
    const serials = findSerials(tokens);
    const first = serials[0], last = serials.at(-1);
    const work = [...new Set(tokens.filter(t => workPattern.test(t.value) &&
      (!first || t.y < first.y-.008)).map(t => t.value))];
    const empty = {order:work.length === 1 ? work[0] : '', rows:[], found:0, score:0, crop:null};
    if (serials.length < 2 || last.n-first.n >= MAX_ROWS) return empty;
    const pitch = median(serials.slice(1).map((t,i) => (t.y-serials[i].y)/(t.n-serials[i].n)));
    const candidates = materialTokens(tokens);
    const hits = serials.map(serial => candidates.filter(t =>
      t.l >= serial.r-.004 && t.l-serial.r <= .29 && Math.abs(t.y-serial.y) < pitch*.59
    ).sort((a,b) => a.l-b.l)[0]).filter(Boolean);
    if (hits.length < 2) return empty;
    const left = median(hits.map(t => t.l)), right = median(hits.map(t => t.r));
    const dx = median(hits.map(t => {
      const closest = [...serials].sort((a,b) => Math.abs(t.y-a.y)-Math.abs(t.y-b.y))[0];
      return t.y-closest.y;
    }));
    const column = candidates.filter(t => Math.abs(t.l-left) <
      Math.min(.09, Math.max(.036,(right-left)*.30))).concat(
      crop ? materialTokens(crop.map(([raw,l,y,r]) => ({value:clean(raw),l,y,r}))) : []);
    const rows = [];
    const foundTokens = new Set();
    // A short gap at the start can occur when OCR misses the first printed number.
    // Keep the slot visible if its expected position is on the page below the header.
    const firstRow = first.n<=3 && first.y-(first.n-1)*pitch>.04 ? 1 : first.n;
    let nextAnchor=0;
    for (let n=firstRow; n<=last.n; n++) {
      while (serials[nextAnchor].n < n) nextAnchor++;
      const after=serials[nextAnchor], before=serials[Math.max(0,nextAnchor-1)];
      const y=after.n===n ? after.y : nextAnchor===0 ? first.y+(n-first.n)*pitch
        : before.y+(after.y-before.y)*(n-before.n)/(after.n-before.n);
      const choices = column.filter(t => !foundTokens.has(t) && Math.abs(t.y-y-dx) < pitch*.49)
        .sort((a,b) => a.y===b.y ? a.l-b.l : Math.abs(a.y-y-dx)-Math.abs(b.y-y-dx));
      const full = choices.find(t => candidates.includes(t));
      const refined = choices[0];
      const chosen = full || refined;
      if (chosen) foundTokens.add(chosen);
      rows.push({n, code:chosen?.value || ''});
    }
    const found=rows.filter(row => row.code).length;
    return {order:empty.order, rows, found, score:found*3+serials.length+(empty.order ? 4 : 0),
      headerEnd:first.y-(first.n-firstRow)*pitch,
      completeSequence:first.n===1&&serials.length===rows.length&&last.y<.94,
      crop:{l:Math.max(0,left-.026),r:Math.min(1,Math.max(...hits.map(t => t.r))+.026)}};
  }

  function validate(order, rows) {
    order=clean(order);
    const items=rows.filter(row=>!row.skipped).map(row=>({n:row.n,code:clean(row.code)}));
    const counts=new Map();
    for (const row of items) counts.set(row.code,(counts.get(row.code)||0)+1);
    const invalid=new Set(items.filter(row=>!editableCode(row.code)||counts.get(row.code)>1).map(row=>row.n));
    const orderValid=order.length<=48&&editableCode(order);
    return {order, items, invalid, orderValid, ready:orderValid&&items.length>0&&!invalid.size};
  }

  return {parse, validate, MAX_ROWS};
})();

if (typeof module !== 'undefined' && module.exports) module.exports=bomPhotoParser;

if (typeof document !== 'undefined' && HAS_NATIVE_MES &&
    typeof window.NativeMES.startBomCapture === 'function') {
  (() => {
    const modalId='bomPhotoModal';
    const order=$('#bomPhotoOrder'), rowsBox=$('#bomPhotoRows'), status=$('#bomPhotoStatus');
    const review=$('#bomDraft'), photo=$('#bomPhotoPreview'), frame=$('#bomPhotoFrame');
    const checked=$('#bomPhotoChecked'), apply=$('#bomPhotoApply'), add=$('#bomAddRowBtn');
    const camera=$('#bomCameraBtn'), gallery=$('#bomGalleryBtn'), input=$('#bomPhotoInput');
    const preview=$('#bomPreviewBtn'), zoom=$('#bomZoomBtn');
    let draft=null;

    function updateControls() {
      const busy=draft?.busy||draft?.camera;
      camera.disabled=gallery.disabled=Boolean(busy);
      review.classList.toggle('hidden',Boolean(busy)||!draft?.image);
    }

    function clearDraft() {
      if (draft?.url) URL.revokeObjectURL(draft.url);
      draft=null;
      input.value='';
      photo.removeAttribute('src');
      rowsBox.replaceChildren();
      order.value='';
      checked.checked=false;
      apply.disabled=true;
      review.classList.add('hidden');
    }

    function setStatus(value, warning=false) {
      status.textContent=value;
      status.classList.toggle('warnnote',warning);
      status.classList.toggle('infonote',!warning);
    }

    function reviewState() {
      const result=bomPhotoParser.validate(order.value,draft.rows);
      order.setAttribute('aria-invalid',String(!result.orderValid));
      for (const row of draft.rows) {
        const field=document.getElementById('bomMaterial'+row.n);
        if (field) field.setAttribute('aria-invalid',String(result.invalid.has(row.n)));
      }
      add.disabled=draft.rows.length>=bomPhotoParser.MAX_ROWS;
      apply.disabled=!(result.ready&&checked.checked);
      let message= '將匯入 '+result.items.length+' 筆料號。';
      if (!result.orderValid) message='請核對並填寫正確的工單編號。';
      else if (!result.items.length) message='至少需要一筆料號。';
      else if (result.invalid.size) message='請處理 '+result.invalid.size+' 列空白、格式錯誤或重複料號。';
      const feedback=$('#bomPhotoValidation');
      if (feedback.textContent!==message) feedback.textContent=message;
      return result;
    }

    function editReview() {
      checked.checked=false;
      reviewState();
    }

    function appendRow(row) {
      const line=document.createElement('div');
      line.className='bomPhotoRow';
      const number=document.createElement('span');
      number.textContent=row.n;
      const code=document.createElement('input');
      code.id='bomMaterial'+row.n;
      code.setAttribute('aria-label','第 '+row.n+' 列料號');
      code.autocomplete='off';
      code.spellcheck=false;
      code.autocapitalize='characters';
      code.maxLength=64;
      code.placeholder='待補料號';
      code.value=row.code;
      code.oninput=()=>{row.code=code.value;editReview()};
      const skip=document.createElement('button');
      skip.className='ghost';
      skip.type='button';
      skip.textContent='略過';
      skip.setAttribute('aria-label','略過第 '+row.n+' 列');
      skip.onclick=()=>{
        row.skipped=!row.skipped;
        code.disabled=row.skipped;
        skip.textContent=row.skipped?'還原':'略過';
        skip.setAttribute('aria-label',skip.textContent+'第 '+row.n+' 列');
        editReview();
      };
      line.append(number,code,skip);
      rowsBox.appendChild(line);
      return code;
    }

    function rotate(canvas, turn) {
      if (!turn) return canvas;
      const out=document.createElement('canvas'), ctx=out.getContext('2d');
      [out.width,out.height]=turn%2?[canvas.height,canvas.width]:[canvas.width,canvas.height];
      ctx.translate(out.width/2,out.height/2);
      ctx.rotate(turn*Math.PI/2);
      ctx.drawImage(canvas,-canvas.width/2,-canvas.height/2);
      return out;
    }

    async function recognize(page) {
      return JSON.parse(await mesNativeAnalyze(page,'bomOcr'));
    }

    function cropPage(page, l, r, bottom, scale) {
      const out=document.createElement('canvas');
      const width=(r-l)*page.width, height=bottom*page.height;
      const factor=Math.min(scale,2400/Math.max(width,height));
      out.width=Math.max(1,Math.round(width*factor));
      out.height=Math.max(1,Math.round(height*factor));
      out.getContext('2d').drawImage(page,l*page.width,0,width,height,0,0,out.width,out.height);
      return out;
    }

    async function setPreview(current, turn) {
      const url=URL.createObjectURL(await new Promise(resolve=>rotate(current.image,turn).toBlob(resolve,'image/jpeg',.89)));
      if (draft!==current || current.turn!==turn) {
        URL.revokeObjectURL(url);
        return;
      }
      if (current.url) URL.revokeObjectURL(current.url);
      current.url=url;
      photo.src=url;
      frame.scrollTo(0,0);
    }

    async function reliablePhoto(result,page) {
      const valid=bomPhotoParser.validate(result.order,result.rows);
      if(!result.completeSequence||!valid.ready||result.found<3||result.headerEnd<=.05)return false;
      const header=await recognize(cropPage(page,0,.76,result.headerEnd-.012,2));
      if(bomPhotoParser.parse(header).order!==result.order)return false;
      const {l,r}=result.crop;
      const strip=await recognize(cropPage(page,l,r,1,1.4));
      const codes=new Map();
      for(const [value] of strip){
        const code=String(value).normalize('NFKC').trim().toUpperCase().replace(/[‐‑‒–—−]/g,'-');
        codes.set(code,(codes.get(code)||0)+1);
      }
      return valid.items.every(row=>codes.get(row.code)===1);
    }

    async function enterPhotoTask(result) {
      const text='工單編號\t'+result.order+'\n序號\t料號\t品名\n'+result.items.map(row=>row.n+'\t'+row.code+'\t').join('\n');
      const items=parseBom(text);
      if(items.length!==result.items.length)throw new Error('BOM 資料格式有誤，請重新核對。');
      await loadTask(makeTask(items,{w:result.order}));
      $('#bomText').value=text;
      importMeta={w:result.order};
      importSource='BOM 照片';
      importedSheet='';
      $('#excelFile').value='';
      $('#excelInfo').textContent='已匯入工單及料號。';
      $('#parseInfo').textContent='照片匯入未填入品名、規格及數量。';
      updateSourceInfo(items);
      invalidateBuiltTask();
      closeModal(modalId);
    }

    async function importWorkQr(raw){
      if(!/^(?:MESCHK2:)|(?:#|[?&])task=/.test(raw||''))return false;
      await loadTask(taskFromScannedValue(raw));
      closeModal(modalId);
      return true;
    }

    async function process(current, bitmap) {
      try {
        current.image=await imageFileToCanvasCompat(bitmap,2400);
      } catch {
        if (draft===current) setStatus('無法開啟照片。請重新拍攝或選取其他圖片。',true);
        return;
      }
      if (draft!==current) return;
      let best={order:'',rows:[],found:0,score:-1}, failure=false;
      let bestTurn=0;
      try {
        for (const turn of [0,3,1,2]) {
          if (draft!==current) return;
          const page=rotate(current.image,turn);
          const elements=await recognize(page);
          const result=bomPhotoParser.parse(elements);
          if (result.score>best.score) {
            best=result;
            bestTurn=turn;
          }
          if (result.found<3) continue;
          let order=result.order;
          if (!order && result.headerEnd>.05 && draft===current) {
            // Retry the header separately without replacing any ambiguous characters.
            const header=await recognize(cropPage(page,0,.76,result.headerEnd-.012,2));
            order=bomPhotoParser.parse(header).order;
          }
          if (draft!==current) return;
          let reviewed=result;
          if (result.found<result.rows.length && result.crop) {
            const {l,r}=result.crop;
            const strip=cropPage(page,l,r,1,1.4);
            const crop=(await recognize(strip)).map(([value,x,y,right])=>[value,l+x*(r-l),y,l+right*(r-l)]);
            reviewed=bomPhotoParser.parse(elements,crop);
          }
          if (order&&!reviewed.order) reviewed={...reviewed,order,score:reviewed.score+4};
          if (reviewed.score>=best.score) {
            best=reviewed;
            bestTurn=turn;
          }
          if (order) break;
        }
      } catch {
        failure=true;
      }
      if (draft!==current) return;
      try {
        if(await reliablePhoto(best,rotate(current.image,bestTurn))&&draft===current){
          await enterPhotoTask(bomPhotoParser.validate(best.order,best.rows));
          return;
        }
      }catch { /* Show source image and preserve candidate rows for review. */ }
      if(draft!==current)return;
      current.turn=bestTurn;
      await setPreview(current,bestTurn);
      if (draft!==current) return;
      frame.classList.remove('hidden','zoom');
      preview.setAttribute('aria-expanded','true');
      preview.textContent='收起照片';
      zoom.setAttribute('aria-pressed','false');
      zoom.textContent='放大照片';
      order.value=best.order;
      current.rows=best.rows.length?best.rows:[{n:1,code:''}];
      rowsBox.replaceChildren();
      for (const row of current.rows) appendRow(row);
      checked.checked=false;
      reviewState();
      if (best.found) {
        const missing=best.rows.length-best.found;
        setStatus('辨識到 '+best.found+' 筆候選料號'+(missing?'，'+missing+' 列待補。':'。')+
          (best.order?'':' 請補填工單編號。'),Boolean(missing)||!best.order);
      } else {
        setStatus(failure?'照片辨識失敗。可重拍或對照照片手動填寫。':
          '沒有辨識到可用的 BOM 明細。可重拍或對照照片手動填寫。',true);
      }
    }

    async function load(source) {
      const current=draft;
      if (!current||current.busy) return;
      current.busy=true;
      setStatus('正在裝置上辨識 BOM…');
      updateControls();
      let file;
      try {
        file=await source();
        if(draft!==current)return;
        let raw='';
        try{raw=await decodeTaskQrImage(file)}catch{}
        if(draft===current&&!await importWorkQr(raw)&&draft===current)await process(current,file);
      } catch(error) {
        if(draft===current)setStatus(error.message||'無法讀取照片，請重試。',true);
      } finally {
        if (draft===current) {
          current.busy=false;
          updateControls();
        }
      }
    }

    $('#bomPhotoBtn').classList.remove('hidden');
    $('#bomPhotoBtn').onclick=()=>{
      if (importBusy) return;
      clearDraft();
      draft={rows:[],busy:false,camera:false};
      $('#bomPhotoAgreement').textContent='我已核對工單及完整料號清單。'+
        ($('#bomText').value.trim()?' 建立後會更新目前的 BOM 草稿。':'');
      setStatus('可掃工單 QR、拍紙本 BOM，或從相簿選取照片。');
      updateControls();
      openModal(modalId,$('#bomPhotoBtn'));
      camera.click();
    };
    $('#'+modalId).addEventListener('mes-modal-close',clearDraft);
    $('#bomCloseBtn').onclick=()=>closeModal(modalId);
    camera.onclick=()=>{
      draft.camera=true;
      updateControls();
      setStatus('正在啟用相機…');
      try { window.NativeMES.startBomCapture(); }
      catch { window.__mesBomCapture('finished','無法啟用相機。可改用選取照片。'); }
    };
    window.__mesBomCapture=(kind,value)=>{
      if(kind==='gallery'){
        if(draft){draft.camera=false;updateControls();input.click()}
      }else if(kind==='qr'){
        if(!draft?.camera)return;
        draft.busy=true;updateControls();
        void importWorkQr(value).catch(error=>setStatus('工單 QR 無法載入：'+error.message,true)).finally(()=>{
          if(draft){draft.busy=false;updateControls()}
        });
      }else if (kind==='photo') {
        if (!draft?.camera) {
          window.NativeMES.releaseSessionPhoto(value);
          return;
        }
        void load(async ()=>{
          try {
            return await window.MESIOS.captureData(value);
          } finally {
            window.NativeMES.releaseSessionPhoto(value);
          }
        });
      } else if (draft?.camera) {
        draft.camera=false;
        if (!draft.busy) setStatus(value||'已取消拍攝。可重新開啟相機或選取照片。',Boolean(value));
        updateControls();
      }
    };
    gallery.onclick=()=>input.click();
    input.onchange=()=>{
      const file=input.files[0];
      input.value='';
      if (file) void load(()=>file);
    };
    preview.onclick=()=>{
      const hidden=frame.classList.toggle('hidden');
      preview.setAttribute('aria-expanded',String(!hidden));
      preview.textContent=hidden?'展開照片':'收起照片';
    };
    zoom.onclick=()=>{
      frame.classList.remove('hidden');
      preview.textContent='收起照片';
      preview.setAttribute('aria-expanded','true');
      const enlarged=frame.classList.toggle('zoom');
      zoom.setAttribute('aria-pressed',String(enlarged));
      zoom.textContent=enlarged?'還原大小':'放大照片';
      frame.scrollTo(0,0);
    };
    $('#bomRotateBtn').onclick=()=>{
      draft.turn=(draft.turn+1)%4;
      void setPreview(draft,draft.turn);
    };
    add.onclick=()=>{
      if (draft.rows.length>=bomPhotoParser.MAX_ROWS) return;
      const row={n:(draft.rows.at(-1)?.n||0)+1,code:''};
      draft.rows.push(row);
      appendRow(row).focus();
      editReview();
    };
    order.oninput=editReview;
    checked.onchange=reviewState;
    apply.onclick=async()=>{
      const result=reviewState();
      if(!result.ready||!checked.checked||importBusy||draft.busy)return;
      const current=draft;
      current.busy=true;apply.disabled=true;updateControls();
      try{await enterPhotoTask(result)}
      catch(error){setStatus(error.message,true)}
      finally{if(draft===current){current.busy=false;updateControls();reviewState()}}
    };
  })();
}
