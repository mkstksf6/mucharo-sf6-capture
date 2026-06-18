-- ============================================================
--  むーちゃろアナライザー キャプチャ v3.3
--  for REFramework / Street Fighter 6
--
--  v3.3での修正:
--   - 【バグ修正】UIウィンドウの×ボタンで閉じられない問題を修正。
--     begin_window に開閉状態(window_open)を渡し、その戻り値を受け取る形にした。
--     ×を押すと window_open=false になり、以降ウィンドウは描画されない。
--     ×で閉じたときは Auto-Record も自動でオフ（= ツールオフ操作とみなす）。
--     記録を続けたままUIを隠したいときは「最小化」を使う（記録は止まらない）。
--     ※再表示は REFramework の「Reset scripts」かSF6再起動で。
--  v3.2での修正:
--   - 【B修正】決着フレームの記録漏れを修正。判定を「両者HP>0」から
--     「両者cap>0（対戦成立中）」に変更。KOでHP=0になる決着フレームも記録される。
--   - 【C追加】各ラウンドの勝者を判定して meta.round_results に記録。
--     自分視点の勝敗(my_wins/opp_wins)も保存し、保存メッセージにも表示。
--  v3.1での修正:
--   - 【バグ修正】My Side が反転して保存される問題を修正（comboを明示ボタンに）
--   - UI・メッセージを英語に統一（文字化け対策）
--  v2〜v3の機能:
--   - 戦闘区間の自動記録 / ラウンド分割 / My Side / 保存名編集
--
--  使い方:
--   1) <SF6>/reframework/autorun/ に置く（旧版は削除して入れ替え）
--   2) SF6でリプレイを再生
--   3) "My Side" で自分が1P/2Pどちらかをボタンで選ぶ（選択中の自分HPで確認）
--   4) "Auto-Record" をオン → 戦闘が始まると自動で記録
--   5) Label に名前を入れて "Save"
--
--  保存先: <SF6>/reframework/data/mucharo_<label>.json
--
--  【SF6アプデで動かなくなったら】壊れやすいのは下記2箇所のみ：
--   (1) read_player() のフィールド名（vital_new, focus_new, pos, speed, alpha 等）
--   (2) read_action() の Rollback...ActEngines[0]._Parent._Engine チェーン
--   それ以外（保存・UI・判定）はSF6内部構造に依存しないので壊れない。
--   全読み取りは try() で保護済み。壊れたフィールドは画面に FAIL と出る。
-- ============================================================

local FIX = 6553600.0   -- 固定小数点 → 実数

-- ---- 内部状態 ----
local auto_record   = false      -- マスタースイッチ
local window_open   = true       -- UIウィンドウの開閉状態（×ボタンで閉じられるように）
local in_combat     = false      -- 現在、戦闘区間か（両者cap>0 = 対戦成立中）
local frames        = {}
local frame_count   = 0
local round_seg     = 0          -- 戦闘区間の通し番号（= ラウンド区切り）
local round_results = {}         -- セグメントごとの勝敗結果（C）
local seg_last_hp1  = nil        -- 区間内で最後に見たHP（勝者判定用）
local seg_last_hp2  = nil
local seg_cur       = nil        -- 現在の区間番号（判定確定用）
local replay_label  = ""
local cur_round     = nil
local cur_timer     = nil
local last_p1       = {}
local last_p2       = {}
local last_status   = "Initializing..."
local char_p1       = nil
local char_p2       = nil
local my_side       = "p1"       -- 自分はどっち側か（"p1" または "p2"。文字列で持ち曖昧性を排除）
local game_version  = nil        -- ゲームバージョン（自動取得を試みる）

-- ---- ヘルパー ----
local function try(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function bitand(a, b)
    local result, bitval = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bitval end
        bitval = bitval * 2
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return result
end

local function read_sfix(o)
    return tonumber(o:call("ToString()"))
end

-- ---- 1プレイヤー分の地の値 ----
local function read_player(cPlayer, cTeam, idx)
    local P = cPlayer[idx]
    local T = cTeam[idx]
    local d = {}
    -- 体力
    d.hp        = try(function() return P.vital_new end)
    d.hp_cap    = try(function() return P.vital_old end)
    d.hp_cool   = try(function() return P.healing_wait end)
    -- ドライブ
    d.drive     = try(function() return P.focus_new end)
    d.drive_cool= try(function() return P.focus_wait end)
    -- SA（取得のみ・理論では不使用）
    d.super     = try(function() return T.mSuperGauge end)
    -- 位置・運動
    d.pos_x     = try(function() return P.pos.x.v / FIX end)
    d.pos_y     = try(function() return P.pos.y.v / FIX end)
    d.vel_x     = try(function() return P.speed.x.v / FIX end)
    d.vel_y     = try(function() return P.speed.y.v / FIX end)
    d.acc_x     = try(function() return P.alpha.x.v / FIX end)
    d.acc_y     = try(function() return P.alpha.y.v / FIX end)
    d.pushback  = try(function() return P.vector_zuri.speed.v / FIX end)
    -- 向き
    d.facing    = try(function() return (bitand(P.BitValue, 128) == 128) and 1 or 0 end)
    -- 接触・状態
    d.hitstun   = try(function() return P.damage_time end)
    d.blockstun = try(function() return P.guard_time end)
    d.hitstop   = try(function() return P.hit_stop end)
    d.throw_inv = try(function() return P.catch_muteki end)
    d.full_inv  = try(function() return P.muteki_time end)
    d.juggle    = try(function() return P.combo_dm_air end)
    d.stance    = try(function() return P.pose_st end)
    d.act_st    = try(function() return P.act_st end)
    d.buff      = try(function() return P.style_timer end)
    return d
end

local function read_action(engine, d)
    d.action_id     = try(function() return engine:get_ActionID() end)
    d.action_frame  = try(function() return math.floor(read_sfix(engine:get_ActionFrame())) end)
    d.action_end    = try(function() return math.floor(read_sfix(engine:get_ActionFrameNum())) end)
    d.action_margin = try(function() return math.floor(read_sfix(engine:get_MarginFrame())) end)
end

-- ---- キャラID（メタデータ用・取れる範囲で）----
local function read_char_ids(cPlayer)
    char_p1 = try(function() return cPlayer[0].CharaID end) or try(function() return cPlayer[0].chara_id end)
    char_p2 = try(function() return cPlayer[1].CharaID end) or try(function() return cPlayer[1].chara_id end)
end

-- ---- JSON保存 ----
local function save()
    -- round_results を seg 順の配列に整える（C）
    local results_list = {}
    for i = 1, round_seg do
        if round_results[i] then
            results_list[#results_list + 1] = round_results[i]
        end
    end
    -- 自分視点の勝敗カウント（ファイル名生成より先に計算）
    local my_wins, opp_wins = 0, 0
    for _, r in ipairs(results_list) do
        if r.winner == my_side then my_wins = my_wins + 1
        elseif r.winner == "p1" or r.winner == "p2" then opp_wins = opp_wins + 1 end
    end

    -- ファイル名（Label空欄なら日時+サイド+勝敗で自動生成）
    local label = replay_label
    if label == nil or label == "" then
        label = os.date("%Y%m%d_%H%M%S")
            .. "_" .. my_side
            .. "_" .. my_wins .. "W" .. opp_wins .. "L"
    end
    -- ファイル名に使えない文字を簡易サニタイズ
    label = label:gsub("[^%w%-_]", "_")

    local out = {
        meta = {
            schema_version = "capture-0.3.2",
            captured_at    = os.date("%Y-%m-%d %H:%M:%S"),
            fps            = 60,
            replay_label   = label,
            game_version   = game_version or "(unknown)",
            my_side        = my_side,                                        -- 自分はどっち側か
            my_char        = (my_side == "p1") and char_p1 or char_p2,       -- 自分のキャラID
            char_p1        = char_p1,
            char_p2        = char_p2,
            frame_count    = #frames,
            round_segments = round_seg,
            round_results  = results_list,                                   -- 各ラウンドの勝敗（C）
            my_wins        = my_wins,                                        -- 自分視点の勝ち数
            opp_wins       = opp_wins,
        },
        frames = frames,
    }
    local fname = "mca_" .. label .. ".json"
    if json.dump_file(fname, out) then
        re.msg("Saved: reframework/data/" .. fname .. "\n"
            .. "my_side=" .. my_side .. " / " .. #frames .. " frames / " .. round_seg .. " rounds\n"
            .. "Result (you): " .. my_wins .. " win / " .. opp_wins .. " lose\n"
            .. "Open with Notepad, or send to AI for analysis.")
    else
        re.msg("Save FAILED")
    end
end

local function fv(v)
    if v == nil then return "FAIL" end
    if type(v) == "number" then return string.format("%.3f", v) end
    return tostring(v)
end

-- ---- ゲームバージョンの自動取得（一度だけ・失敗しても無害）----
local function detect_game_version()
    if game_version ~= nil then return end
    -- 取得できれば入る。取れなくても (unknown) のまま進む。
    game_version = try(function()
        local app = sdk.find_type_definition("app.ApplicationFunc")
        if app then
            local v = app:get_method("getVersionString")
            if v then return tostring(v:call(nil)) end
        end
        return nil
    end)
end

-- ---- 毎フレーム ----
re.on_frame(function()
    detect_game_version()
    pcall(function()
        local gB = sdk.find_type_definition("gBattle")
        if not gB then last_status = "gBattle type not found"; in_combat = false; return end

        local sRound  = gB:get_field("Round"):get_data(nil)
        local sGame   = gB:get_field("Game"):get_data(nil)
        local sPlayer = gB:get_field("Player"):get_data(nil)
        local sTeam   = gB:get_field("Team"):get_data(nil)
        if not (sRound and sGame and sPlayer and sTeam) then
            last_status = "Not in battle (menu/loading)"; in_combat = false; return
        end

        local cPlayer = sPlayer.mcPlayer
        local cTeam   = sTeam.mcTeam
        if not (cPlayer and cTeam) then last_status = "Player array empty"; in_combat = false; return end

        cur_round = try(function() return sRound.RoundNo end)
        cur_timer = try(function() return sGame.stage_timer end)

        last_p1 = read_player(cPlayer, cTeam, 0)
        last_p2 = read_player(cPlayer, cTeam, 1)

        pcall(function()
            local rb = gB:get_field("Rollback"):get_data():GetLatestEngine()
            read_action(rb.ActEngines[0]._Parent._Engine, last_p1)
            read_action(rb.ActEngines[1]._Parent._Engine, last_p2)
        end)

        -- ---- 戦闘区間の判定（B修正）----
        -- 「対戦が成立している間（両者cap>0）」を戦闘区間とする。
        -- KOでHP=0になった決着フレームも、capは残るので記録され続ける。
        -- 選択画面・演出では cap=0 になるため、そこは自然に除外される。
        local hp1, hp2 = last_p1.hp, last_p2.hp
        local cap1, cap2 = last_p1.hp_cap, last_p2.hp_cap
        local combat_now =
            (cap1 ~= nil and cap1 > 0) and (cap2 ~= nil and cap2 > 0) and
            (hp1 ~= nil) and (hp2 ~= nil)

        if combat_now then
            -- 区間に入った瞬間 → 新しいラウンド区切り
            if not in_combat then
                round_seg = round_seg + 1
                if char_p1 == nil then read_char_ids(cPlayer) end
            end
            in_combat = true
            last_status = "In combat (seg " .. round_seg .. ")"

            -- 直近のHPを覚えておく（C: 区間終了時の勝者判定に使う）
            seg_last_hp1 = hp1
            seg_last_hp2 = hp2
            seg_cur = round_seg

            if auto_record then
                frame_count = frame_count + 1
                frames[#frames + 1] = {
                    f = frame_count, seg = round_seg,
                    round = cur_round, timer = cur_timer,
                    p1 = last_p1, p2 = last_p2,
                }
            end
        else
            -- 区間から抜けた瞬間（in_combat true→false）= ラウンド決着（C）
            if in_combat and seg_cur ~= nil then
                local winner = "unknown"
                if seg_last_hp1 ~= nil and seg_last_hp2 ~= nil then
                    if seg_last_hp1 <= 0 and seg_last_hp2 > 0 then
                        winner = "p2"
                    elseif seg_last_hp2 <= 0 and seg_last_hp1 > 0 then
                        winner = "p1"
                    elseif seg_last_hp1 > seg_last_hp2 then
                        winner = "p1"   -- 時間切れ等：残HPが多い方
                    elseif seg_last_hp2 > seg_last_hp1 then
                        winner = "p2"
                    else
                        winner = "draw"
                    end
                end
                round_results[seg_cur] = {
                    seg = seg_cur, winner = winner,
                    hp1_end = seg_last_hp1, hp2_end = seg_last_hp2,
                }
                seg_cur = nil
            end
            in_combat = false
            if hp1 ~= nil then
                last_status = "Not in combat (cutscene/KO/select)"
            else
                last_status = "HP unreadable"
            end
        end
    end)

    -- ---- UI ----
    -- window_open を渡し、×ボタンが押されたら戻り値が false になる。
    -- 閉じられたら以降は描画しない（次フレームも window_open=false が維持される）。
    -- 再表示したいときは REFramework の「Reset scripts」かSF6再起動で復活する。
    if not window_open then return end
    window_open = imgui.begin_window("Mucharo Capture v3.3", window_open, 0)
    if not window_open then
        -- ×ボタンで閉じた = ツールをオフにする操作とみなし、記録も止める。
        -- （記録を続けたままUIを隠したいときは「最小化」を使う。バッファは保持される）
        auto_record = false
        imgui.end_window()
        return
    end

    imgui.text("Status: " .. last_status)
    imgui.text("Round: " .. fv(cur_round) .. "   Timer: " .. fv(cur_timer))
    imgui.text("Version: " .. (game_version or "(unknown)"))
    imgui.separator()

    imgui.text("--- P1 ---")
    imgui.text("HP: " .. fv(last_p1.hp) .. " / cap " .. fv(last_p1.hp_cap))
    imgui.text("Drive: " .. fv(last_p1.drive) .. "   Super: " .. fv(last_p1.super))
    imgui.text("PosX: " .. fv(last_p1.pos_x) .. "   AccX: " .. fv(last_p1.acc_x))
    imgui.text("Hitstun: " .. fv(last_p1.hitstun) .. "   Blockstun: " .. fv(last_p1.blockstun))
    imgui.text("--- P2 ---")
    imgui.text("HP: " .. fv(last_p2.hp) .. "   PosX: " .. fv(last_p2.pos_x))
    imgui.separator()

    -- My Side selection (explicit buttons to avoid index ambiguity)
    imgui.text("My Side (who are you?)")
    if imgui.button(((my_side == "p1") and "[*] " or "[ ] ") .. "1P (Left)") then
        my_side = "p1"
    end
    if imgui.button(((my_side == "p2") and "[*] " or "[ ] ") .. "2P (Right)") then
        my_side = "p2"
    end
    local my_char_now = (my_side == "p1") and last_p1 or last_p2
    imgui.text(">> Selected: " .. my_side .. "  (My HP: " .. fv(my_char_now.hp) .. ")")
    imgui.separator()

    local changed
    changed, auto_record = imgui.checkbox("Auto-Record (combat only)", auto_record)
    imgui.text("Recording: " .. (auto_record and (in_combat and "● ON / In combat" or "○ ON / Waiting") or "OFF"))
    imgui.text("Frames: " .. frame_count .. "   Rounds: " .. round_seg)
    -- 勝敗結果の表示（C）
    local res_str = ""
    for i = 1, round_seg do
        if round_results[i] then
            res_str = res_str .. "seg" .. i .. ":" .. round_results[i].winner .. "  "
        end
    end
    if res_str ~= "" then imgui.text("Results: " .. res_str) end
    changed, replay_label = imgui.input_text("Label (filename / replay ID)", replay_label)

    if imgui.button("Save") then
        save()
    end
    if imgui.button("Clear (reset buffer)") then
        frames = {}
        frame_count = 0
        round_seg = 0
        round_results = {}
        seg_last_hp1 = nil
        seg_last_hp2 = nil
        seg_cur = nil
        char_p1 = nil
        char_p2 = nil
        re.msg("Buffer cleared")
    end

    imgui.end_window()
end)
