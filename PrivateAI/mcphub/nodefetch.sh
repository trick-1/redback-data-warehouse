docker exec -it mcp-hub-mcphub-1 sh -lc 'node -e "
(async () => {
  try {
    const r = await fetch(\"http://10.137.17.254:4045/health\", {
      headers: { Authorization: \"98bb99ab7db3f86cdaba0276c9b913890cacfa92fa7514a01a52c3792d1753e3\"}
    });
    console.log(\"status\", r.status);
    console.log(await r.text());
  } catch (e) {
    console.error(\"FETCH_ERR\", e);
  }
})();"'
