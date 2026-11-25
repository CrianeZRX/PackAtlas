/* Original pencil-and-grid archive cutaway. Drawn only when the selection changes. */
function inkSketch(value) {
  const paper = '#fff8e9', ink = '#302b23', red = '#b64e3a', blue = '#557e98', gold = '#eac66f';
  function draw(canvas, sketch) {
    const c = canvas.getContext('2d');
    c.clearRect(0, 0, canvas.width, canvas.height);
    c.lineWidth = 2;
    c.lineJoin = 'round';
    c.lineCap = 'round';
    sketch(c);
  }
  function line(c, points, color = ink, fill) {
    c.beginPath();
    for (let i = 0; i < points.length; i++) c[i ? 'lineTo' : 'moveTo'](...points[i]);
    if (fill) { c.closePath(); c.fillStyle = fill; c.fill(); }
    c.strokeStyle = color; c.stroke();
  }
  function label(c, value, x, y, color = ink, size = 14) {
    c.fillStyle = color;
    c.font = size + 'px "Courier Prime", monospace';
    c.fillText(value, x, y);
  }
  function zipper(c, x, y, len) {
    line(c, [[x,y],[x+1,y+len]], ink);
    for(let i = 3; i < len; i += 6) line(c, [[x-3,y+i],[x+4,y+i+1]], ink);
    line(c, [[x-4,y-3],[x+5,y-3],[x+5,y+6],[x-3,y+7],[x-4,y-3]], ink, '#e29071');
  }
  draw(document.getElementById('mark'), c => {
    line(c, [[5,11],[38,8],[43,35],[33,42],[7,40]], ink, gold);
    line(c, [[6,11],[32,14],[33,41],[43,35]], ink);
    line(c, [[36,17],[39,16],[41,28],[38,29]], ink, paper);
    zipper(c,18,14,19);
  });
  draw(document.getElementById('archiveDrawing'), c => {
    c.fillStyle = '#aec8d8';
    for (let y = 19; y < 285; y += 25) for (let x = 20; x < 608; x += 25) {
      if ((x+y)%4) c.fillRect(x,y,1.5,1.5);
    }
    // Field annotations, registration marks and a measured baseline.
    c.lineWidth = 1;
    line(c, [[21,41],[21,23],[39,23]], blue);
    line(c, [[578,23],[597,23],[597,42]], blue);
    line(c, [[21,262],[21,282],[39,282]], blue);
    line(c, [[579,282],[597,282],[597,262]], blue);
    label(c, 'FIG. A', 48, 28, red, 12);
    label(c, '1 : 1', 540, 28, blue, 12);
    for (let i=63; i<=566; i+=16) line(c, [[i,265],[i,271]], blue);
    line(c, [[62,270],[565,270]], blue);
    c.lineWidth = 2;
    // Archive carton with an unlocked zipper.
    line(c, [[125,179],[221,152],[281,190],[211,236],[118,211]], '#b4c7cc', '#c3d4db');
    line(c, [[114,127],[191,144],[258,113],[255,182],[184,217],[115,198]], ink, '#ecc67a');
    line(c, [[191,144],[184,217],[255,182],[258,113]], ink, '#d5a659');
    line(c, [[114,127],[178,87],[258,113],[191,144]], ink, '#f3d998');
    line(c, [[114,127],[79,97],[149,64],[178,87]], ink, '#f8e5ba');
    line(c, [[178,87],[220,60],[289,79],[258,113]], ink, '#f8e5ba');
    line(c, [[116,130],[192,149],[258,116]], '#a5623f');
    c.save();
    c.translate(150,140);c.rotate(.15);zipper(c,0,0,55);c.restore();
    for (let i=0;i<6;i++) line(c, [[212+i*6,172-i*2],[205+i*6,185-i*2]], '#a97a46');
    line(c, [[205,68],[214,48]], red);line(c, [[190,60],[189,44]], red);line(c, [[224,69],[238,58]], red);
    label(c,value.format||'ZIP / RAR / 7Z', 96, 250, ink, 14);
    // Signal across the fold, then paper and a folder already unpacked.
    c.setLineDash([5,6]);line(c, [[269,153],[307,142],[353,136],[397,128]], red);c.setLineDash([]);
    line(c, [[384,122],[399,127],[388,137]], red);
    line(c, [[413,123],[461,116],[475,91],[539,93],[538,191],[431,207]], ink, '#ead38c');
    line(c, [[414,128],[534,111],[554,179],[431,208]], ink, '#f5d87e');
    line(c, [[439,117],[437,67],[481,56],[500,69],[509,110]], ink, paper);
    line(c, [[481,56],[483,73],[500,69]], ink, '#edd2b7');
    line(c, [[449,83],[487,76],[489,83],[451,90]], blue);
    line(c, [[451,98],[484,91]], blue);
    c.save();c.translate(518,201);c.rotate(-.12);
    line(c, [[-58,-11],[33,-12],[37,13],[-59,15]], '#4f765e', '#e0eddf');
    label(c,value.done ? 'VERIFIED' : 'EXTRACT', -49, 6, '#3c6b51', 15);
    c.restore();
  });
}
if (document.fonts) document.fonts.ready.then(() => window.redrawArchive?.());
