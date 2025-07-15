const SCRIPT_VERSION = 'v20250715';

(function () {
  // == 工具函数模块 ==
  const utils = (() => {
    function formatFileSize(bytes) {
      if (bytes === 0) return { value: '0', unit: 'B' };
      const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
      let size = bytes;
      let unitIndex = 0;
      while (size >= 1024 && unitIndex < units.length - 1) {
        size /= 1024;
        unitIndex++;
      }
      return {
        value: size.toFixed(unitIndex === 0 ? 0 : 2),
        unit: units[unitIndex]
      };
    }

    function calculatePercentage(used, total) {
      used = Number(used);
      total = Number(total);
      if (used > 1e15 || total > 1e15) {
        used = used / 1e10;
        total = total / 1e10;
      }
      return ((used / total) * 100).toFixed(1);
    }

    function getHslGradientColor(percentage) {
      const clamp = (val, min, max) => Math.min(Math.max(val, min), max);
      const lerp = (start, end, t) => start + (end - start) * t;
      const p = clamp(Number(percentage), 0, 100);
      let h, s, l;
      if (p <= 35) {
        const t = p / 35;
        h = lerp(120, 160, t);
        s = lerp(60, 80, t);
        l = lerp(40, 50, t);
      } else if (p <= 85) {
        const t = (p - 35) / 50;
        h = lerp(32, 0, t);
        s = lerp(85, 75, t);
        l = lerp(55, 50, t);
      } else {
        const t = (p - 85) / 15;
        h = 0;
        s = 75;
        l = lerp(50, 45, t);
      }
      return `hsl(${h.toFixed(0)}, ${s.toFixed(0)}%, ${l.toFixed(0)}%)`;
    }

    return {
      formatFileSize,
      calculatePercentage,
      getHslGradientColor
    };
  })();

  // == 渲染模块 ==
  const trafficRenderer = (() => {
    function renderTrafficStats(serverMap) {
      serverMap.forEach((serverData, serverName) => {
        const targetElement = Array.from(document.querySelectorAll('section.grid.items-center.gap-2'))
          .find(el => el.textContent.trim().includes(serverName));
        if (!targetElement) return;

        const usedFormatted = utils.formatFileSize(serverData.transfer);
        const totalFormatted = utils.formatFileSize(serverData.max);
        const percentage = utils.calculatePercentage(serverData.transfer, serverData.max);
        const progressColor = utils.getHslGradientColor(percentage);
        const fromFormatted = new Date(serverData.from).toLocaleDateString('zh-CN');
        const toFormatted = new Date(serverData.to).toLocaleDateString('zh-CN');
        const uniqueClassName = 'traffic-stats-for-server-' + serverData.id;

        const insertedElement = targetElement.parentNode.querySelector('.' + uniqueClassName);
        if (insertedElement) {
          insertedElement.querySelector('.used-traffic').textContent = usedFormatted.value;
          insertedElement.querySelector('.used-unit').textContent = usedFormatted.unit;
          insertedElement.querySelector('.total-traffic').textContent = totalFormatted.value;
          insertedElement.querySelector('.total-unit').textContent = totalFormatted.unit;
          insertedElement.querySelector('.percentage-value').textContent = `${fromFormatted} - ${toFormatted}`;
          const bar = insertedElement.querySelector('.progress-bar');
          bar.style.width = percentage + '%';
          bar.style.backgroundColor = progressColor;
          return;
        }

        const newElement = document.createElement('div');
        newElement.classList.add('space-y-1.5', 'new-inserted-element', uniqueClassName);
        newElement.style.width = '100%';
        newElement.innerHTML = `
          <div class="flex items-center justify-between">
            <div class="flex items-baseline gap-1">
              <span class="text-[10px] font-medium text-neutral-800 dark:text-neutral-200 used-traffic">${usedFormatted.value}</span>
              <span class="text-[10px] font-medium text-neutral-800 dark:text-neutral-200 used-unit">${usedFormatted.unit}</span>
              <span class="text-[10px] text-neutral-500 dark:text-neutral-400">/ </span>
              <span class="text-[10px] text-neutral-500 dark:text-neutral-400 total-traffic">${totalFormatted.value}</span>
              <span class="text-[10px] text-neutral-500 dark:text-neutral-400 total-unit">${totalFormatted.unit}</span>
            </div>
            <span class="text-[10px] font-medium text-neutral-600 dark:text-neutral-300 percentage-value">${fromFormatted} - ${toFormatted}</span>
          </div>
          <div class="relative" style="height: 3px;">
            <div class="absolute inset-0 bg-neutral-100 dark:bg-neutral-800 rounded-full" style="height: 100%"></div>
            <div class="absolute inset-0 rounded-full transition-all duration-300 progress-bar" style="width: ${percentage}%; height: 100%; background-color: ${progressColor};"></div>
          </div>
        `;

        const containerDiv = targetElement.closest('div');
        const insertAfter = containerDiv?.querySelector('section.flex.items-center.w-full.justify-between.gap-1')
          || containerDiv?.querySelector('section.grid.items-center.gap-3');
        if (insertAfter) {
          insertAfter.after(newElement);
        } else {
          targetElement.after(newElement);
        }
      });
    }

    return {
      renderTrafficStats
    };
  })();

  // == 数据模块 ==
  const trafficDataManager = (() => {
    function fetchTrafficData(callback) {
      fetch('/api/v1/service')
        。then(res => res.json())
        。then(data => {
          if (!data.success) return;
          const rawStats = data.data.cycle_transfer_stats;
          const serverMap = new Map();

          for (const cycleId in rawStats) {
            const cycle = rawStats[cycleId];
            if (!cycle.server_name || !cycle.transfer) continue;
            for (const serverId in cycle.server_name) {
              const serverName = cycle.server_name[serverId];
              const transfer = cycle.transfer[serverId];
              const max = cycle.max;
              const from = cycle.from;
              const to = cycle.to;
              if (serverName && transfer !== undefined && max && from && to) {
                serverMap.set(serverName, {
                  id: serverId,
                  transfer,
                  max,
                  from,
                  to,
                  name: cycle.name
                });
              }
            }
          }

          callback(serverMap);
        })
        。catch(err => {
          console.error('[TrafficData] 请求失败:', err);
        });
    }

    return {
      fetchTrafficData
    };
  })();

  // == 主程序入口 ==
  function main() {
    function updateTrafficStats() {
      trafficDataManager.fetchTrafficData(serverMap => {
        trafficRenderer.renderTrafficStats(serverMap);
      });
    }

    // 初始延迟执行一次
    setTimeout(updateTrafficStats, 100);
    // 周期刷新
    setInterval(updateTrafficStats, 3000);
  }

  // 设置标志变量
  window.FixedTopServerName = true;

  // 启动主程序
  main();
})();
