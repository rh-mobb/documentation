const codeBlocks = document.querySelectorAll('pre > code')
codeBlocks.forEach(function (block) {
  
  const pfTooltip = document.createElement('pf-tooltip');
  const pfButton = document.createElement('pf-button');
  const pfIcon = document.createElement('pf-icon');

  pfButton.className = 'copy-code-button';
  pfButton.plain = true;
  pfButton.label = 'Copy';
  pfButton.tabIndex = '0';

  pfIcon.icon = 'copy';

  const toolTipSpan = document.createElement('span');
  toolTipSpan.setAttribute('slot', 'content');
  toolTipSpan.textContent = pfButton.label;

  pfButton.appendChild(pfIcon);
  pfTooltip.appendChild(pfButton);
  pfTooltip.appendChild(toolTipSpan);
  
  const pre = block.parentNode;
  if (pre.parentNode.classList.contains('highlight')) {
    const highlight = pre.parentNode;
    highlight.append(pfTooltip);
  } else {
    pre.append(pfTooltip);
  }

  const sleep = (ms) => new Promise(r => setTimeout(r, ms));

  pfButton.addEventListener('click', async function () {
    await navigator.clipboard.writeText(pre.textContent);
    toolTipSpan.textContent = 'Copied';
    await sleep(1500);
    toolTipSpan.textContent = 'Copy';
  });
});
