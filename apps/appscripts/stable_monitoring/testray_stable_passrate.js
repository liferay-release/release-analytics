/**
 * @OnlyCurrentDoc
 */
function onOpen() {
  const ui = SpreadsheetApp.getUi();
  
  ui.createMenu('🔄 Testray')
    .addItem('🔄 Refresh Stable Data', 'fetchStableData')
    // .addItem('📅 Update Timeline', 'updateStableTimeline')
    // .addItem('❌ Fetch Failed Tests', 'fetchFailedTests')
    .addItem('♻️ Remove CI builds and recalculate metrics', 'recalculateAllMetrics')
    .addToUi();
}

function recalculateAllMetrics() {
  propagateCITags(); // <-- Stamps the sheets first!
  updateTestMetrics();
  updateWeeklyMetrics();
  SpreadsheetApp.getActiveSpreadsheet().toast('Metrics recalculated and CI tags propagated!', '✅ Done');
}

function auth() {
  const ui = SpreadsheetApp.getUi();

  // Prompt for Client ID every time
  const idPrompt = ui.prompt('Testray Authentication', 'Please enter your Client ID:', ui.ButtonSet.OK_CANCEL);
  if (idPrompt.getSelectedButton() !== ui.Button.OK) {
    throw new Error('Script canceled: Client ID is required.');
  }
  const clientId = idPrompt.getResponseText().trim();

  // Prompt for Client Secret every time
  const secretPrompt = ui.prompt('Testray Authentication', 'Please enter your Client Secret:', ui.ButtonSet.OK_CANCEL);
  if (secretPrompt.getSelectedButton() !== ui.Button.OK) {
    throw new Error('Script canceled: Client Secret is required.');
  }
  const clientSecret = secretPrompt.getResponseText().trim();

  const accessTokenUrl = "https://testray.liferay.com/o/oauth2/token";
  
  // Get the access token using the newly inputted credentials
  const tokenResponse = UrlFetchApp.fetch(accessTokenUrl, {
    method: "post",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    payload: {
      "grant_type": "client_credentials",
      "client_id": clientId,
      "client_secret": clientSecret
    }
  });

  const tokenData = JSON.parse(tokenResponse.getContentText());
  return tokenData.access_token;
}

function fetchStableData() {
  // Authorization
  const accessToken = auth();
  
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const dataTab = ss.getSheetByName("Stable_fetch");
  const routineID = 79529;

  const baseEndpoint = "https://testray.liferay.com/o/testray-rest/v1.0/testray-status-metrics/by-testray-routineId/" 
  + routineID 
  + "/testray-builds-metrics?pageSize=500";

  const cutoffDate = new Date("2025-10-01").getTime();

  const lastRow = dataTab.getLastRow();
  let existingBuildIDs = new Set();

  if (lastRow === 0) {
    const headers = [
      "RoutineID", "TestrayBuildID", "TestrayBuildName", "TestrayBuildLink", "TestrayBuildGitHash", "TestrayBuildDate", "InProgress", "Incomplete", 
      "TestFix", "Blocked", "Untested", "Failed", "NotPassed", "Passed", "Total", 
      "PassRate", "", "CPUUsage"
    ];
    dataTab.appendRow(headers);
  } else if (lastRow > 1) { 
    const idRange = dataTab.getRange(2, 2, lastRow - 1, 1).getValues();
    idRange.forEach(row => {
      if(row[0]) existingBuildIDs.add(row[0].toString());
    });
  }

  let newRows = [];
  const bugFixDate = new Date("2026-03-25").getTime();
  let page = 1;
  let reachedCutoff = false;

  while (!reachedCutoff) {
    const apiEndpoint = baseEndpoint + "&page=" + page;
    ss.toast(`Fetching page ${page}...`, '⚙️ Working...', -1);

    const response = UrlFetchApp.fetch(apiEndpoint, {
      headers: { "Authorization": `Bearer ${accessToken}` }
    });

    const content = JSON.parse(response.getContentText());
    const items = content["items"] || [];

    if (items.length === 0) break;

    for (let index = 0; index < items.length; index++) {
      const build = items[index];
      const testrayBuildID = build["testrayBuildId"];
      const testrayBuildDate = build["testrayBuildDueDate"];

      if (testrayBuildDate && new Date(testrayBuildDate).getTime() < cutoffDate) {
        reachedCutoff = true;
        break;
      }

      if (testrayBuildID > 1 && !existingBuildIDs.has(testrayBuildID.toString())) {
        const buildLink = `https://testray.liferay.com/web/testray#/project/35392/routines/79529/build/${testrayBuildID}`;
        const testrayBuildName = build["testrayBuildName"];
        const testrayBuildGitHash = build["testrayBuildGitHash"];
        const metrics = build["testrayStatusMetric"];

        const inProgress = metrics["inProgress"];
        const incomplete = metrics["incomplete"];
        const testfix = metrics["testfix"];
        const blocked = metrics["blocked"];
        const failed = metrics["failed"];
        const passed = metrics["passed"];

        let untested = metrics["untested"];
        let total = metrics["total"];

        const buildDateObj = new Date(testrayBuildDate);
        if (buildDateObj.getTime() < bugFixDate) {
          if (untested > 0) untested -= 1;
          if (total > 0) total -= 1;
        }

        const notPassed = inProgress + incomplete + testfix + blocked + untested + failed;
        const passRate = total > 0 ? (passed / total) : 0;
        const cpuUsage = build["testrayBuildCPUUseTime"];

        newRows.push([
          routineID, testrayBuildID, testrayBuildName, buildLink, testrayBuildGitHash, testrayBuildDate, inProgress, incomplete,
          testfix, blocked, untested, failed, notPassed, passed, total,
          passRate, "", cpuUsage
        ]);
      }
    } // end for

    page++;
  } // end while

  if (newRows.length > 0) {
    newRows.reverse(); 

    const startRow = dataTab.getLastRow() + 1;
    const numRows = newRows.length;
    const numCols = newRows[0].length;
    
    const range = dataTab.getRange(startRow, 1, numRows, numCols);
    range.setValues(newRows);
    
    dataTab.getRange(startRow, 6, numRows, 1).setNumberFormat("yyyy-MM-dd");
    dataTab.getRange(startRow, 16, numRows, 1).setNumberFormat("0.0000");
    
    SpreadsheetApp.getActiveSpreadsheet().toast(`Successfully added ${numRows} new records!`, 'Fetch Complete');
  } else {
    SpreadsheetApp.getActiveSpreadsheet().toast('No new builds found.', 'Up to Date');
  }

  updateStableTimeline();
  fetchFailedTests(accessToken);
}

function updateStableTimeline() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const fetchTab = ss.getSheetByName("Stable_fetch");
  
  let timelineTab = ss.getSheetByName("Stable_timeline");
  if (!timelineTab) {
    timelineTab = ss.insertSheet("Stable_timeline");
  }
  
  const fetchLastRow = fetchTab.getLastRow();
  if (fetchLastRow < 2) {
    return;
  }
  
  const fetchData = fetchTab.getRange(2, 1, fetchLastRow - 1, 16).getValues(); 
  
  const timelineLastRow = timelineTab.getLastRow();
  let existingIDs = new Set();
  
  if (timelineLastRow === 0) {
    timelineTab.appendRow(["RoutineID", "TestrayBuildID", "TestrayBuildLink", "TestrayBuildGitHash", "TestrayBuildDate", "PassRate", "Comment"]);
  } else if (timelineLastRow > 1) { 
    const idRange = timelineTab.getRange(2, 2, timelineLastRow - 1, 1).getValues();
    idRange.forEach(row => {
      if(row[0]) existingIDs.add(row[0].toString());
    });
  }
  
  const targetDate = new Date("2026-03-23").getTime();
  let timelineRows = [];
  
  fetchData.forEach(row => {
    const routineID = row[0];
    const buildID = row[1];
    const buildLink = row[3];
    const buildGitHash = row[4]; 
    const buildDateRaw = row[5]; 
    const passRate = row[15]; 
    
    if (!buildDateRaw) return; 
    const buildDate = new Date(buildDateRaw);
    
    if (buildDate.getTime() >= targetDate && buildID && !existingIDs.has(buildID.toString())) {
      let comment = "";
      if (passRate >= 1) { 
        comment = "PASS";
      }
      
      timelineRows.push([routineID, buildID, buildLink, buildGitHash, buildDateRaw, passRate, comment]);
    }
  });
  
  if (timelineRows.length > 0) {
    const startRow = timelineTab.getLastRow() + 1;
    const range = timelineTab.getRange(startRow, 1, timelineRows.length, 7);
    range.setValues(timelineRows);
    
    timelineTab.getRange(startRow, 5, timelineRows.length, 1).setNumberFormat("yyyy-MM-dd");
    timelineTab.getRange(startRow, 6, timelineRows.length, 1).setNumberFormat("0.0000");
  }
}

function fetchFailedTests(token) {
  const accessToken = token || auth();
  
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const fetchTab = ss.getSheetByName("Stable_fetch");
  
  let failedTab = ss.getSheetByName("Stable_failedTests");
  if (!failedTab) {
    failedTab = ss.insertSheet("Stable_failedTests");
  }

  const fetchLastRow = fetchTab.getLastRow();
  if (fetchLastRow < 2) return;
  
  const fetchData = fetchTab.getRange(2, 1, fetchLastRow - 1, 16).getValues();

  const failedLastRow = failedTab.getLastRow();
  let existingFailedIDs = new Set();

  if (failedLastRow === 0) {
    failedTab.appendRow(["TestrayBuildID", "TestrayBuildLink", "TestrayBuildDate", "TestrayCaseName", "TestrayCaseTypeName", "TestrayComponentName", "TestrayTeamName", "Status", "Error"]);
  } else if (failedLastRow > 1) { 
    const idRange = failedTab.getRange(2, 1, failedLastRow - 1, 1).getValues();
    idRange.forEach(row => {
      if(row[0]) existingFailedIDs.add(row[0].toString());
    });
  }

  let buildsToProcess = [];
  for (let i = 0; i < fetchData.length; i++) {
    const buildID = fetchData[i][1];
    const buildLink = fetchData[i][3]; 
    const buildDate = fetchData[i][5]; 
    const passRate = fetchData[i][15]; 
    
    if (passRate < 1 && buildID && !existingFailedIDs.has(buildID.toString())) {
      buildsToProcess.push({
        id: buildID,
        link: buildLink,
        date: buildDate
      });
    }
  }

  if (buildsToProcess.length > 0) {
    ss.toast(`Found ${buildsToProcess.length} builds with failed tests. Fetching details from the API, please wait...`, '⚙️ Working...', -1);
  }

  let failedRows = [];
  let processedCount = 0;
  const bugFixDate = new Date("2026-03-25").getTime(); 

  for (let i = 0; i < buildsToProcess.length; i++) {
    const build = buildsToProcess[i];
    const apiEndpoint = `https://testray.liferay.com/o/testray-rest/v1.0/testray-case-result/${build.id}?status=UNTESTED%2C%20FAILED&pageSize=500`;
    
    const isBeforeFix = new Date(build.date).getTime() < bugFixDate;
    
    try {
      const response = UrlFetchApp.fetch(apiEndpoint, {
        headers: {
          "Authorization": `Bearer ${accessToken}`
        }
      });

      const content = JSON.parse(response.getContentText());
      const items = content["items"] || [];
      
      let itemsAddedForBuild = 0;

      if (items.length > 0) {
        items.forEach(item => {
          const caseName = item["testrayCaseName"];
          
          const isIgnoredClayWeb = (caseName === ":apps:frontend-js:frontend-js-clay-web:packageRunTest");
          
          if (caseName !== "Top Level Build" && !(isBeforeFix && isIgnoredClayWeb)) {
            failedRows.push([
              build.id, 
              build.link, 
              build.date, 
              caseName, 
              item["testrayCaseTypeName"], 
              item["testrayComponentName"], 
              item["testrayTeamName"], 
              item["status"],
              item["error"] || "" 
            ]);
            itemsAddedForBuild++;
          }
        });
      } 
      
      if (itemsAddedForBuild === 0) {
        failedRows.push([build.id, build.link, build.date, "No failed items (or filtered out)", "", "", "", "", ""]);
      }
      
      processedCount++;

      if (processedCount % 10 === 0) {
        ss.toast(`Fetched ${processedCount} of ${buildsToProcess.length} builds...`, '⚙️ Working...', -1);
      }

    } catch (e) {
      Logger.log(`Failed to fetch test results for build ${build.id}: ${e.message}`);
    }
  }

  if (failedRows.length > 0) {
    const startRow = failedTab.getLastRow() + 1;
    const range = failedTab.getRange(startRow, 1, failedRows.length, 9);
    range.setValues(failedRows);
    
    failedTab.getRange(startRow, 3, failedRows.length, 1).setNumberFormat("yyyy-MM-dd");
    failedTab.getRange(startRow, 9, failedRows.length, 1).setWrapStrategy(SpreadsheetApp.WrapStrategy.CLIP);
    
    ss.toast(`Successfully fetched failed tests for ${processedCount} builds.`, '✅ Failed Tests Updated');
  } else if (buildsToProcess.length === 0) {
    ss.toast(`No new failed tests to fetch.`, '✅ Up to Date');
  }

  // Trigger metrics calculations automatically at the end!
  updateTestMetrics();
  updateWeeklyMetrics();
}

function updateTestMetrics() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const fetchTab = ss.getSheetByName("Stable_fetch");
  const failedTab = ss.getSheetByName("Stable_failedTests");
  
  let metricsTab = ss.getSheetByName("Stable_testMetrics");
  if (!metricsTab) {
    metricsTab = ss.insertSheet("Stable_testMetrics");
  }
  
  const ignoredBuilds = getIgnoredBuilds(ss); // <-- ADDED: Fetch ignored builds

  // 1. Calculate Total Builds per Era from Stable_fetch
  const fetchLastRow = fetchTab.getLastRow();
  if (fetchLastRow < 2) return;
  
  const fetchData = fetchTab.getRange(2, 1, fetchLastRow - 1, 6).getValues();
  
  let preChangeBuilds = new Set();
  let postChangeBuilds = new Set();
  const changeDate = new Date("2026-03-23").getTime();
  
  fetchData.forEach(row => {
    const buildID = row[1];
    const buildDateRaw = row[5];
    
    // ADDED: !ignoredBuilds.has filter
    if (buildID && buildDateRaw && !ignoredBuilds.has(buildID.toString())) {
      const buildTime = new Date(buildDateRaw).getTime();
      if (buildTime >= changeDate) {
        postChangeBuilds.add(buildID);
      } else {
        preChangeBuilds.add(buildID);
      }
    }
  });
  
  const preChangeTotal = preChangeBuilds.size;
  const postChangeTotal = postChangeBuilds.size;
  
  // 2. Count Failures per Test per Era from Stable_failedTests
  const failedLastRow = failedTab.getLastRow();
  if (failedLastRow < 2) return;
  
  const failedData = failedTab.getRange(2, 1, failedLastRow - 1, 4).getValues();
  
  let testStats = {};
  
  failedData.forEach(row => {
    const buildID = row[0];
    const buildDateRaw = row[2];
    const caseName = row[3];
    
    // ADDED: ignoredBuilds.has filter
    if (!buildID || caseName === "No failed items (or filtered out)" || ignoredBuilds.has(buildID.toString())) return;
    
    if (!testStats[caseName]) {
      testStats[caseName] = { "Pre-Change": new Set(), "Post-Change": new Set() };
    }
    
    const buildTime = new Date(buildDateRaw).getTime();
    if (buildTime >= changeDate) {
      testStats[caseName]["Post-Change"].add(buildID);
    } else {
      testStats[caseName]["Pre-Change"].add(buildID);
    }
  });
  
  // 3. Generate the Flat Rows for Looker Studio
  let outputRows = [];
  outputRows.push(["TestrayCaseName", "Process Era", "Failures", "Total Builds", "Failure Rate"]);
  
  for (const caseName in testStats) {
    const preFailures = testStats[caseName]["Pre-Change"].size;
    const postFailures = testStats[caseName]["Post-Change"].size;
    
    // Write Pre-Change Row
    if (preChangeTotal > 0) {
        outputRows.push([
          caseName, 
          "Pre-Change", 
          preFailures, 
          preChangeTotal, 
          preFailures / preChangeTotal
        ]);
    }
    
    // Write Post-Change Row
    if (postChangeTotal > 0) {
        outputRows.push([
          caseName, 
          "Post-Change", 
          postFailures, 
          postChangeTotal, 
          postFailures / postChangeTotal
        ]);
    }
  }
  
  // 4. Write data to the Sheet
  metricsTab.clear(); 
  metricsTab.getRange(1, 1, outputRows.length, 5).setValues(outputRows);
  metricsTab.getRange(2, 5, outputRows.length - 1, 1).setNumberFormat("0.0000");
}

function updateWeeklyMetrics() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const fetchTab = ss.getSheetByName("Stable_fetch");
  const failedTab = ss.getSheetByName("Stable_failedTests");
  
  let weeklyTab = ss.getSheetByName("Stable_weeklyMetrics");
  if (!weeklyTab) {
    weeklyTab = ss.insertSheet("Stable_weeklyMetrics");
  }

  const ignoredBuilds = getIgnoredBuilds(ss); // <-- ADDED: Fetch ignored builds
  
  // Helper to find the Monday of a given date
  function getMonday(dateRaw) {
    const d = new Date(dateRaw);
    const day = d.getDay();
    const diff = d.getDate() - day + (day === 0 ? -6 : 1); 
    const monday = new Date(d.setDate(diff));
    monday.setHours(0,0,0,0);
    return Utilities.formatDate(monday, Session.getScriptTimeZone(), "yyyy-MM-dd");
  }

  // 1. Calculate Total Builds per Week
  const fetchLastRow = fetchTab.getLastRow();
  if (fetchLastRow < 2) return;
  const fetchData = fetchTab.getRange(2, 1, fetchLastRow - 1, 6).getValues();
  
  let weeklyBuilds = {}; 
  
  fetchData.forEach(row => {
    const buildID = row[1];
    const buildDateRaw = row[5];
    
    // ADDED: !ignoredBuilds.has filter
    if (buildID && buildDateRaw && !ignoredBuilds.has(buildID.toString())) {
      const weekString = getMonday(buildDateRaw);
      if (!weeklyBuilds[weekString]) {
        weeklyBuilds[weekString] = new Set();
      }
      weeklyBuilds[weekString].add(buildID);
    }
  });

  // 2. Count Failures per Test per Week
  const failedLastRow = failedTab.getLastRow();
  if (failedLastRow < 2) return;
  const failedData = failedTab.getRange(2, 1, failedLastRow - 1, 4).getValues();
  
  let testWeeklyStats = {};
  
  failedData.forEach(row => {
    const buildID = row[0];
    const buildDateRaw = row[2];
    const caseName = row[3];
    
    // ADDED: ignoredBuilds.has filter
    if (!buildID || caseName === "No failed items (or filtered out)" || !buildDateRaw || ignoredBuilds.has(buildID.toString())) return;
    
    const weekString = getMonday(buildDateRaw);
    
    if (!testWeeklyStats[caseName]) {
      testWeeklyStats[caseName] = {};
    }
    if (!testWeeklyStats[caseName][weekString]) {
      testWeeklyStats[caseName][weekString] = new Set();
    }
    
    testWeeklyStats[caseName][weekString].add(buildID);
  });

  // 3. Generate Flat Output Rows
  let outputRows = [];
  outputRows.push(["TestrayCaseName", "Week of", "Failures", "Total Weekly Builds", "Failure Rate"]);
  
  for (const caseName in testWeeklyStats) {
    for (const weekString in testWeeklyStats[caseName]) {
      const failures = testWeeklyStats[caseName][weekString].size;
      const totalBuilds = weeklyBuilds[weekString] ? weeklyBuilds[weekString].size : 0;
      
      if (totalBuilds > 0) {
        outputRows.push([
          caseName,
          weekString,
          failures,
          totalBuilds,
          failures / totalBuilds
        ]);
      }
    }
  }

  // 4. Write data to the Sheet
  weeklyTab.clear(); 
  if (outputRows.length > 1) {
    weeklyTab.getRange(1, 1, outputRows.length, 5).setValues(outputRows);
    weeklyTab.getRange(2, 2, outputRows.length - 1, 1).setNumberFormat("yyyy-MM-dd");
    weeklyTab.getRange(2, 5, outputRows.length - 1, 1).setNumberFormat("0.0000");
  }
}

function getIgnoredBuilds(ss) {
  const timelineTab = ss.getSheetByName("Stable_timeline");
  let ignored = new Set();
  
  if (!timelineTab) return ignored;
  const lastRow = timelineTab.getLastRow();
  if (lastRow < 2) return ignored;

  // Grab columns A through G (up to the Comment column)
  const data = timelineTab.getRange(2, 1, lastRow - 1, 7).getValues();
  
  data.forEach(row => {
    const buildID = row[1];
    const comment = row[6] ? row[6].toString().toUpperCase() : ""; 
    
    // If the comment includes "CI" (case-insensitive), add it to the naughty list
    if (comment.includes("CI") && buildID) {
      ignored.add(buildID.toString());
    }
  });
  
  return ignored;
}

function propagateCITags() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const ignoredBuilds = getIgnoredBuilds(ss); 

  // 1. Stamp the Stable_fetch sheet (Column R / 18)
  const fetchTab = ss.getSheetByName("Stable_fetch");
  if (fetchTab) {
    const fetchLastRow = fetchTab.getLastRow();
    if (fetchLastRow > 1) {
      fetchTab.getRange("S1").setValue("Ignore_Build"); 
      const ids = fetchTab.getRange(2, 2, fetchLastRow - 1, 1).getValues(); 
      
      // Define tagValues FIRST
      let tagValues = [];
      ids.forEach(row => {
        tagValues.push([ignoredBuilds.has(row[0].toString()) ? "CI" : null]);
      });

      // Define the range and THEN clear/set values
      const range = fetchTab.getRange(2, 19, fetchLastRow - 1, 1);
      range.clearContent(); 
      range.setValues(tagValues);
    }
  }

  // 2. Stamp the Stable_failedTests sheet (Column J / 10)
  const failedTab = ss.getSheetByName("Stable_failedTests");
  if (failedTab) {
    const failedLastRow = failedTab.getLastRow();
    if (failedLastRow > 1) {
      failedTab.getRange("J1").setValue("Ignore_Build"); 
      const ids = failedTab.getRange(2, 1, failedLastRow - 1, 1).getValues(); 
      
      // Define tagValues FIRST
      let tagValues = [];
      ids.forEach(row => {
        tagValues.push([ignoredBuilds.has(row[0].toString()) ? "CI" : null]);
      });

      // Define rangeFailed and THEN clear/set values
      const rangeFailed = failedTab.getRange(2, 10, failedLastRow - 1, 1);
      rangeFailed.clearContent(); 
      rangeFailed.setValues(tagValues);
    }
  }
}