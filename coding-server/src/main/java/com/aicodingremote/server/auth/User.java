package com.aicodingremote.server.auth;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * 用户记录。以前 users.json 只存 account→"salt:hash" 太扁,后续要挂更多信息
 * (昵称、注册方式、邮箱是否验证、时间戳,将来还有头像/套餐/设置…),
 * 这里改成结构化对象,以后加字段只动这个类。
 *
 * 持久化为 data/users.json:  { "<email>": { ...User... }, ... }
 * @JsonIgnoreProperties(ignoreUnknown=true):向前兼容,旧版读到新字段不报错。
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public class User {
    /** 登录邮箱(同时是主键,小写)。 */
    public String email;
    /** 密码哈希 "saltHex:sha256(salt+password)";为空表示未设密码(仅外部登录)。 */
    public String passwordHash;
    /** 展示昵称(Google 带来的 name,或邮箱注册时默认邮箱前缀)。 */
    public String displayName;
    /** 账号创建方式:"email"(邮箱验证码注册)| "google"(Google 验证邮箱)。 */
    public String provider;
    /** 邮箱是否已验证(邮箱注册/Google 均为已验证)。 */
    public boolean emailVerified;
    /** 创建/更新时间(epoch ms)。 */
    public long createdAt;
    public long updatedAt;

    public User() {}

    public User(String email, String provider) {
        long now = System.currentTimeMillis();
        this.email = email;
        this.provider = provider;
        this.emailVerified = true;
        this.createdAt = now;
        this.updatedAt = now;
    }

    public boolean hasPassword() {
        return passwordHash != null && !passwordHash.isBlank();
    }
}
