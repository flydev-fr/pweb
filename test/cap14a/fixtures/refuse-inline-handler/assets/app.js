// The signage corpus' classic script. It is here to be REFERENCED, never
// scanned: pweb.assets.htmlpolicy reads only the documents the MIME
// resolver types as text/html, and a .js asset is not one of them.
//
// The markup-shaped strings below are the point. If a future revision ever
// widened the scanned set to JavaScript, this file would start reporting
// findings for text that no engine parses as HTML.
(function () {
  var stage = document.getElementById('stage');
  var cfg = JSON.parse(document.getElementById('config').textContent);
  var slide = '<article class="slide" onclick="never()">a > b</article>';
  var link = 'javascript:void(0)';
  document.getElementById('headline').textContent = 'rotate ' + cfg.rotateMs;
  if (stage && slide && link) {
    stage.setAttribute('data-ready', '1');
  }
})();
