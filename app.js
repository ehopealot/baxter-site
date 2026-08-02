/* Conversation reveal: plays the exchange through once when the panel is
   in view. Each Baxter reply is preceded by an in-place typing indicator
   (three dots overlaying the message text), so the panel's box stays
   reserved from the start and never resizes as messages arrive.

   Safety: the markup is complete without JS. The script is the only thing
   that adds .is-staged (which hides the messages) and the typing dots;
   reduced motion and no-JS both leave the full conversation on screen.
   The chat is role="img" with a full transcript in its label, so the
   staging never affects screen readers. */
(function () {
  var log = document.querySelector("#chat-log");
  if (!log) return;

  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduced) return;

  var msgs = Array.prototype.slice.call(log.querySelectorAll(".msg"));
  if (!msgs.length) return;
  log.classList.add("is-staged");

  function makeDots() {
    var s = document.createElement("span");
    s.className = "typing-dots";
    s.setAttribute("aria-hidden", "true");
    s.append(
      document.createElement("i"),
      document.createElement("i"),
      document.createElement("i"),
    );
    return s;
  }

  // For each Baxter reply, drop the dots inside its msg-body as an absolute
  // overlay covering the text area. The <p>s keep their text in flow (color
  // hidden while typing, so the box matches the final reply), and the dots
  // sit on top. Result: the row's height is the same during typing and after
  // the reply, so the panel never grows or shrinks.
  msgs.forEach(function (m) {
    if (m.classList.contains("is-bax")) {
      var body = m.querySelector(".msg-body");
      if (body) body.append(makeDots());
      m.classList.add("is-typing");
    }
  });

  function wait(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  async function play() {
    await wait(300);
    for (var i = 0; i < msgs.length; i++) {
      var m = msgs[i];

      // Row enters the panel. For Baxter this happens with the typing state
      // active, so the row arrives as "Baxter is typing".
      m.classList.add("is-in");

      if (m.classList.contains("is-bax")) {
        await wait(900); // the typing beat
        m.classList.remove("is-typing"); // text fades in, dots fade out
        await wait(300); // let the reply settle before the next row
        // After Baxter's first reply, a longer beat so the reader appears to
        // take it in before following up.
        if (i === 1) await wait(850);
      } else {
        await wait(650);
      }
    }
  }

  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      if (entries.some(function (e) { return e.isIntersecting; })) {
        io.disconnect();
        play();
      }
    }, { threshold: 0.35 });
    io.observe(log);
  } else {
    play();
  }
})();

/* Marks the nav link for whichever section you're currently reading. Nothing
   here is load-bearing: with JS off the nav is still five working anchors,
   just without the highlight. */
(function () {
  var links = Array.prototype.slice.call(
    document.querySelectorAll(".topnav a[href^='#']")
  );
  if (!links.length || !window.IntersectionObserver) return;

  var byId = {};
  var sections = [];
  links.forEach(function (link) {
    var section = document.getElementById(link.hash.slice(1));
    if (!section) return;
    byId[section.id] = link;
    sections.push(section);
  });
  if (!sections.length) return;

  var visible = {};

  function paint() {
    // Topmost visible section wins, so scrolling past a short section doesn't
    // leave two links lit or flicker between them.
    var current = null;
    sections.forEach(function (section) {
      if (visible[section.id] && !current) current = section;
    });
    links.forEach(function (link) {
      if (current && byId[current.id] === link) link.setAttribute("aria-current", "true");
      else link.removeAttribute("aria-current");
    });
  }

  var observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        visible[entry.target.id] = entry.isIntersecting;
      });
      paint();
    },
    // Discount the sticky topbar at the top, and require a section to reach
    // the upper half of the viewport before it counts as the one you're on.
    { rootMargin: "-15% 0px -55% 0px" }
  );

  sections.forEach(function (section) {
    observer.observe(section);
  });
})();

/* Copy buttons on the code blocks. Injected rather than authored into the
   markup, so a browser without the clipboard API gets no button instead of a
   dead one. */
(function () {
  if (!navigator.clipboard || !navigator.clipboard.writeText) return;

  var blocks = Array.prototype.slice.call(document.querySelectorAll("pre"));
  if (!blocks.length) return;

  // One shared live region: the button's own label change isn't announced
  // reliably across screen readers, and one region beats seven.
  var live = document.createElement("div");
  live.className = "sr-only";
  live.setAttribute("role", "status");
  document.body.appendChild(live);

  var shortcut = /Mac|iPhone|iPad/.test(navigator.platform || "") ? "⌘C" : "Ctrl+C";

  blocks.forEach(function (pre) {
    var wrap = document.createElement("div");
    wrap.className = "snip";
    pre.parentNode.insertBefore(wrap, pre);

    // Above the block, not floating over it: several of these commands are
    // wider than their container and scroll, so an overlaid button would sit
    // on top of the code it's offering to copy.
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy";
    btn.textContent = "Copy";
    wrap.appendChild(btn);
    wrap.appendChild(pre);

    var revert;
    function say(label, announce) {
      btn.textContent = label;
      if (announce) {
        live.textContent = "";
        live.textContent = announce;
      }
      window.clearTimeout(revert);
      revert = window.setTimeout(function () {
        btn.textContent = "Copy";
      }, 2000);
    }

    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(pre.innerText.replace(/\s+$/, "")).then(
        function () {
          say("Copied", "Copied to clipboard");
        },
        function () {
          // Select the block so the keyboard shortcut still gets them there.
          var range = document.createRange();
          range.selectNodeContents(pre);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          say(shortcut, "Copying was blocked. The text is selected, so press " + shortcut + ".");
        }
      );
    });
  });
})();
