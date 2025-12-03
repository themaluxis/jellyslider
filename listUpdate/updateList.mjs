import fs from 'fs';
import dotenv from 'dotenv';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const config = require('../modules/listConfig.json');

dotenv.config();

const LISTS_DIR = '../list/';
const JELLYFIN_URL = process.env.JELLYFIN_URL;
const JELLYFIN_TOKEN = process.env.JELLYFIN_TOKEN;

if (!JELLYFIN_URL || !JELLYFIN_TOKEN) {
  console.error("❌ ERROR: JELLYFIN_URL or JELLYFIN_TOKEN environment variable is missing!");
  process.exit(1);
}

const userHistories = {};

async function getActiveSessions() {
  try {
    const response = await fetch(`${JELLYFIN_URL}/Sessions`, {
      headers: { Authorization: `MediaBrowser Token="${JELLYFIN_TOKEN}"` }
    });
    return await response.json();
  } catch (error) {
    console.error("⛔ Error fetching session information:", error.message);
    return [];
  }
}

function getListFilePath(userId) {
  return `${LISTS_DIR}list_${userId}.txt`;
}

async function fetchAllItems(userId) {
  let allItems = [];
  let startIndex = 0;

  try {
    const initialResponse = await fetch(
      `${JELLYFIN_URL}/Users/${userId}/Items?${config.listcustomQueryString}&Limit=1`,
      {
        headers: {
          Authorization: `MediaBrowser Token="${JELLYFIN_TOKEN}"`,
          'Content-Type': 'application/json'
        }
      }
    );

    const initialData = await initialResponse.json();
    const totalRecords = initialData.TotalRecordCount || 0;
    const dynamicLimit = totalRecords < 1000 ? totalRecords :
                         totalRecords < 5000 ? 1000 : 2000;

    console.log(`ℹ️ [${userId}] Total ${totalRecords} items, limit: ${dynamicLimit}`);

    while (startIndex < totalRecords) {
      const response = await fetch(
        `${JELLYFIN_URL}/Users/${userId}/Items?${config.listcustomQueryString}&Limit=${dynamicLimit}&StartIndex=${startIndex}`,
        {
          headers: {
            Authorization: `MediaBrowser Token="${JELLYFIN_TOKEN}"`,
            'Content-Type': 'application/json'
          }
        }
      );

      const data = await response.json();
      if (data.Items?.length > 0) {
        allItems = allItems.concat(data.Items);
        startIndex += data.Items.length;
      } else {
        break;
      }
    }
    return allItems;
  } catch (error) {
    console.error(`⛔ [${userId}] Fetch error: ${error.message}`);
    return [];
  }
}

function shuffleArray(array) {
  for (let i = array.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [array[i], array[j]] = [array[j], array[i]];
  }
  return array;
}

async function getRandomContentIds(userId, limit = config.itemLimit) {
  try {
    const minPerType = config.garantiLimit !== undefined ? config.garantiLimit : 1;

    const allItems = await fetchAllItems(userId);
    if (allItems.length === 0) {
      console.warn(`⚠️ [${userId}] No content found for user`);
      return [];
    }

    console.log(`ℹ️ [${userId}] Guarantee limit: ${minPerType} items/type`);
    const itemsByType = allItems.reduce((acc, item) => {
      if (!acc[item.Type]) acc[item.Type] = [];
      acc[item.Type].push(item);
      return acc;
    }, {});

    console.log(`📊 [${userId}] Content Distribution:`,
      Object.entries(itemsByType).map(([type, items]) => `${type}: ${items.length}`).join(', '));
    const availableTypes = Object.keys(itemsByType).filter(type => itemsByType[type].length > 0);
    const guaranteedItems = [];

    availableTypes.forEach(type => {
      const shuffled = shuffleArray([...itemsByType[type]]);
      const takeCount = Math.min(minPerType, itemsByType[type].length);
      guaranteedItems.push(...shuffled.slice(0, takeCount));
    });

    const remainingItems = shuffleArray(
      allItems.filter(item => !guaranteedItems.includes(item))
    );

    const selectedItems = [
      ...guaranteedItems,
      ...remainingItems.slice(0, limit - guaranteedItems.length)
    ];

    if (!userHistories[userId]) {
      userHistories[userId] = [];
    }
    const history = userHistories[userId];
    const historyLimit = config.listLimit || 30;
    const lastHistory = history.slice(-historyLimit);
    const excludedIds = new Set();
    lastHistory.forEach(list => list.forEach(id => excludedIds.add(id)));

    const filteredItems = selectedItems.filter(item => !excludedIds.has(item.Id));
    const finalItems = shuffleArray([
      ...(filteredItems.length >= limit
        ? filteredItems.slice(0, limit)
        : [
            ...filteredItems,
            ...shuffleArray(allItems)
              .filter(item => !filteredItems.includes(item))
              .slice(0, limit - filteredItems.length)
          ])
    ]);

    const ids = finalItems.map(item => item.Id);

    history.push(ids);
    if (history.length > historyLimit) {
      history.shift();
    }

    const typeDistribution = finalItems.reduce((acc, item) => {
      acc[item.Type] = (acc[item.Type] || 0) + 1;
      return acc;
    }, {});

    console.log(`✅ [${userId}] ${ids.length} items selected (Distribution: ${
      Object.entries(typeDistribution)
        .map(([type, count]) => `${type}: ${count}`)
        .join(', ')
    }) | History size: ${history.length}/${historyLimit}`);

    return ids;
  } catch (error) {
    console.error(`⛔ [${userId}] Error selecting content:`, error.message);
    return [];
  }
}

async function updateListFileForUser(userId) {
  const newIds = await getRandomContentIds(userId);
  if (newIds.length === 0) {
    console.log(`ℹ️ [${userId}] No new content found to update`);
    return;
  }

  const listFilePath = getListFilePath(userId);
  try {
    await fs.promises.writeFile(listFilePath, newIds.join('\n'), 'utf8');
    console.log(`🔄 [${userId}] List file updated (${newIds.length} items)`);
  } catch (error) {
    console.error(`⛔ [${userId}] File write error:`, error.message);
  }
}

async function updateListFilesForActiveUsers() {
  try {
    console.log("\n=== List Update Started ===");
    const sessions = await getActiveSessions();

    if (sessions.length === 0) {
      console.log("ℹ️ No active users found");
      return;
    }

    console.log(`👥 ${sessions.length} active users detected`);
    for (const session of sessions) {
      await updateListFileForUser(session.UserId);
    }
    console.log("=== List Update Completed ===\n");
  } catch (error) {
    console.error("⛔ List update error:", error.message);
  }
}

updateListFilesForActiveUsers().catch(error => {
  console.error("⛔ Initial update error:", error.message);
});

const interval = setInterval(updateListFilesForActiveUsers, config.listRefresh || 300000);


process.on('SIGTERM', () => {
  console.log("🛑 SIGTERM received - Shutting down...");
  clearInterval(interval);
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log("🛑 SIGINT received - Shutting down...");
  clearInterval(interval);
  process.exit(0);
});